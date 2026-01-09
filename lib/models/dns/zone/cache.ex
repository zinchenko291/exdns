defmodule Models.Dns.Zone.Cache do
  @moduledoc false

  use GenServer

  require Logger

  alias Models.Dns.Zone.{Cluster, Server, Storage, Supervisor}

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec fetch(String.t()) :: {:ok, map()} | :not_found | {:error, String.t()}
  def fetch(domain), do: GenServer.call(__MODULE__, {:fetch, domain})

  @spec fetch_local(String.t()) :: {:ok, map()} | :not_found | {:error, String.t()}
  def fetch_local(domain), do: GenServer.call(__MODULE__, {:fetch_local, domain})

  @spec put(String.t(), map()) :: :ok | {:error, String.t()}
  def put(domain, data), do: GenServer.call(__MODULE__, {:put, domain, data})

  @spec create(String.t(), map()) :: :ok | {:error, String.t()}
  def create(domain, data), do: GenServer.call(__MODULE__, {:create, domain, data})

  @spec update(String.t(), map()) :: :ok | :not_found | {:error, String.t()}
  def update(domain, data), do: GenServer.call(__MODULE__, {:update, domain, data})

  @spec update(String.t(), map(), non_neg_integer()) :: :ok | :not_found | {:error, String.t()}
  def update(domain, data, expected_version),
    do: GenServer.call(__MODULE__, {:update, domain, data, expected_version})

  @spec delete(String.t()) :: :ok | :not_found | {:error, String.t()}
  def delete(domain), do: GenServer.call(__MODULE__, {:delete, domain})

  @spec apply_change(atom(), String.t(), map() | nil) :: :ok | {:error, String.t()}
  def apply_change(action, domain, data \\ nil),
    do: GenServer.call(__MODULE__, {:apply_change, action, domain, data})

  @impl GenServer
  def init(:ok) do
    {:ok, %{servers: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:fetch, domain}, _from, state) when is_binary(domain) do
    Logger.info("[Zone.Cache] fetch #{domain}")
    case ensure_server(domain, state) do
      {:ok, pid, state} ->
        reply =
          case Server.get(pid) do
            {:ok, data} -> {:ok, data}
            other -> other
          end

        {:reply, reply, state}

      {:error, _} = err ->
        {:reply, err, state}

      :not_found ->
        case Cluster.fetch_remote(domain) do
          {:ok, data} -> {:reply, {:ok, data}, state}
          :not_found -> {:reply, :not_found, state}
          {:error, _} = err -> {:reply, err, state}
        end
    end
  end

  def handle_call({:fetch_local, domain}, _from, state) when is_binary(domain) do
    Logger.debug("[Zone.Cache] fetch_local #{domain}")
    case ensure_server(domain, state) do
      {:ok, pid, state} ->
        reply =
          case Server.get(pid) do
            {:ok, data} -> {:ok, data}
            other -> other
          end

        {:reply, reply, state}

      {:error, _} = err ->
        {:reply, err, state}

      :not_found ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:put, domain, data}, _from, state) when is_binary(domain) and is_map(data) do
    Logger.info("[Zone.Cache] put #{domain}")
    {reply, state} = handle_put(domain, data, state)
    {:reply, reply, state}
  end

  def handle_call({:put, _domain, _data}, _from, state) do
    {:reply, {:error, "invalid zone data"}, state}
  end

  def handle_call({:create, domain, data}, _from, state)
      when is_binary(domain) and is_map(data) do
    Logger.info("[Zone.Cache] create #{domain}")
    data = ensure_version(data, 1)

    case Storage.exists?(domain) do
      {:ok, true} ->
        {:reply, {:error, "zone already exists"}, state}

      {:ok, false} ->
        with :ok <- Storage.write_atomic(domain, data),
             {:ok, pid} <- start_server(domain, data) do
          ref = Process.monitor(pid)
          servers = Map.put(state.servers, domain, pid)
          monitors = Map.put(state.monitors, ref, {domain, pid})
          new_state = %{state | servers: servers, monitors: monitors}

          case Cluster.broadcast_change(:create, domain, data) do
            {:ok, _ack_nodes} ->
              {:reply, :ok, new_state}

            {:error, _reason, ack_nodes} = err ->
              rollback_create(domain, new_state)
              Cluster.rollback_change(:create, domain, nil, ack_nodes)
              {:reply, err, new_state}
          end
        else
          {:error, _} = err -> {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:create, _domain, _data}, _from, state) do
    {:reply, {:error, "invalid zone data"}, state}
  end

  def handle_call({:update, domain, data}, from, state)
      when is_binary(domain) and is_map(data) do
    Logger.info("[Zone.Cache] update #{domain}")
    expected = Map.get(data, "version")

    if is_integer(expected) do
      handle_call({:update, domain, data, expected}, from, state)
    else
      {:reply, {:error, "version is required for update"}, state}
    end
  end

  def handle_call({:update, domain, data, expected_version}, _from, state)
      when is_binary(domain) and is_map(data) and is_integer(expected_version) and
             expected_version >= 1 do
    {reply, new_data, previous, state} = process_update(domain, data, expected_version, state)
    reply =
      if reply == :ok and is_map(new_data) do
        case Cluster.broadcast_change(:update, domain, new_data) do
          {:ok, _ack_nodes} ->
            :ok

          {:error, _reason, ack_nodes} = err ->
            rollback_update(domain, previous, state)
            Cluster.rollback_change(:update, domain, previous, ack_nodes)
            err
        end
      else
        reply
      end

    {:reply, reply, state}
  end

  def handle_call({:update, _domain, _data}, _from, state) do
    {:reply, {:error, "invalid zone data"}, state}
  end

  def handle_call({:update, _domain, _data, _expected}, _from, state) do
    {:reply, {:error, "invalid zone data"}, state}
  end

  def handle_call({:delete, domain}, _from, state) when is_binary(domain) do
    Logger.info("[Zone.Cache] delete #{domain}")
    {reply, state} = handle_delete(domain, state)
    {:reply, reply, state}
  end

  def handle_call({:apply_change, action, domain, data}, _from, state)
      when is_atom(action) and is_binary(domain) do
    Logger.debug("[Zone.Cache] apply_change #{action} #{domain}")
    {reply, state} = apply_local_change(action, domain, data, state)
    {:reply, reply, state}
  end

  def handle_call({:delete, _domain}, _from, state) do
    {:reply, {:error, "invalid domain"}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{domain, ^pid}, monitors} ->
        servers = Map.delete(state.servers, domain)
        {:noreply, %{state | servers: servers, monitors: monitors}}

      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_server(domain, state, data \\ nil) do
    case Map.fetch(state.servers, domain) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid, state}
        else
          ensure_server(domain, %{state | servers: Map.delete(state.servers, domain)}, data)
        end

      :error ->
        with {:ok, data} <- load_zone_data(domain, data),
             {:ok, pid} <- start_server(domain, data) do
          ref = Process.monitor(pid)
          servers = Map.put(state.servers, domain, pid)
          monitors = Map.put(state.monitors, ref, {domain, pid})
          {:ok, pid, %{state | servers: servers, monitors: monitors}}
        else
          :not_found -> :not_found
          {:error, _} = err -> err
        end
    end
  end

  defp load_zone_data(_domain, data) when is_map(data), do: {:ok, data}

  defp load_zone_data(domain, _data) do
    case Storage.read(domain) do
      {:ok, data} -> {:ok, data}
      :not_found -> :not_found
      {:error, _} = err -> err
    end
  end

  defp start_server(domain, data) do
    DynamicSupervisor.start_child(Supervisor, {Server, {domain, data}})
  end

  defp stop_server(domain, state) do
    case Map.fetch(state.servers, domain) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(Supervisor, pid)
        {ref, monitors} = pop_monitor(state.monitors, domain, pid)
        servers = Map.delete(state.servers, domain)

        if ref do
          Process.demonitor(ref, [:flush])
        end

        %{state | servers: servers, monitors: monitors}

      :error ->
        state
    end
  end

  defp server_present(domain, state) do
    case Map.fetch(state.servers, domain) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {state, true}
        else
          {%{state | servers: Map.delete(state.servers, domain)}, false}
        end

      :error ->
        {state, false}
    end
  end

  defp pop_monitor(monitors, domain, pid) do
    case Enum.find(monitors, fn {_ref, {d, p}} -> d == domain and p == pid end) do
      {ref, _} ->
        {ref, Map.delete(monitors, ref)}

      nil ->
        {nil, monitors}
    end
  end

  defp ensure_version(data, version) do
    case Map.get(data, "version") do
      nil -> Map.put(data, "version", version)
      v -> Map.put(data, "version", v)
    end
  end

  defp ensure_version_match(data, expected) do
    case Map.get(data, "version") do
      ^expected -> :ok
      nil -> {:error, "zone version is missing"}
      _ -> {:error, "version mismatch"}
    end
  end

  defp process_update(domain, data, expected_version, state) do
    case Storage.exists?(domain) do
      {:ok, true} ->
        process_update_existing(domain, data, expected_version, state)

      {:ok, false} ->
        {:not_found, nil, nil, state}

      {:error, _} = err ->
        {err, nil, nil, state}
    end
  end

  defp process_update_existing(domain, data, expected_version, state) do
    case ensure_server(domain, state) do
      {:ok, pid, state} ->
        case update_server(pid, data, expected_version) do
          {:ok, new_data, previous} -> {:ok, new_data, previous, state}
          {:error, _} = err -> {err, nil, nil, state}
        end

      {:error, _} = err ->
        {err, nil, nil, state}

      :not_found ->
        {{:error, "unable to start zone server"}, nil, nil, state}
    end
  end

  defp update_server(pid, data, expected_version) do
    with {:ok, current} <- Server.get(pid),
         :ok <- ensure_version_match(current, expected_version),
         new_data <- Map.put(data, "version", expected_version + 1),
         :ok <- Storage.validate_zone(new_data) do
      case Server.put(pid, new_data) do
        :ok -> {:ok, new_data, current}
        {:error, _} = err -> err
      end
    end
  end

  defp handle_put(domain, data, state) do
    case ensure_server(domain, state, data) do
      {:ok, pid, state} ->
        {put_reply, state} = put_with_replication(domain, data, pid, state)
        {put_reply, state}

      {:error, _} = err ->
        {err, state}

      :not_found ->
        {{:error, "unable to start zone server"}, state}
    end
  end

  defp put_with_replication(domain, data, pid, state) do
    previous = fetch_previous(pid)

    case Server.put(pid, data) do
      :ok ->
        {handle_replication(:put, domain, data, previous, state), state}

      {:error, _} = err ->
        {err, state}
    end
  end

  defp handle_delete(domain, state) do
    {state, has_server} = server_present(domain, state)

    case Storage.delete(domain) do
      :ok ->
        previous = fetch_previous_local(domain, state)
        reply = handle_replication(:delete, domain, nil, previous, state)
        {reply, stop_server(domain, state)}

      :not_found ->
        if has_server do
          previous = fetch_previous_local(domain, state)
          reply = handle_replication(:delete, domain, nil, previous, state)
          {reply, stop_server(domain, state)}
        else
          {:not_found, state}
        end

      {:error, _} = err ->
        {err, state}
    end
  end

  defp handle_replication(:put, domain, data, previous, state) do
    case Cluster.broadcast_change(:put, domain, data) do
      {:ok, _ack_nodes} ->
        :ok

      {:error, _reason, ack_nodes} = err ->
        rollback_put(domain, previous, state)
        Cluster.rollback_change(:put, domain, previous, ack_nodes)
        err
    end
  end

  defp handle_replication(:delete, domain, _data, previous, state) do
    case Cluster.broadcast_change(:delete, domain, nil) do
      {:ok, _ack_nodes} ->
        :ok

      {:error, _reason, ack_nodes} = err ->
        rollback_delete(domain, previous, state)
        Cluster.rollback_change(:delete, domain, previous, ack_nodes)
        err
    end
  end

  defp fetch_previous(pid) do
    case Server.get(pid) do
      {:ok, data} -> data
      _ -> nil
    end
  end

  defp fetch_previous_local(domain, state) do
    case Map.fetch(state.servers, domain) do
      {:ok, pid} -> fetch_previous(pid)
      :error -> nil
    end
  end

  defp rollback_create(domain, state) do
    _ = Storage.delete(domain)
    _ = stop_server(domain, state)
    :ok
  end

  defp rollback_put(_domain, nil, _state), do: :ok

  defp rollback_put(domain, previous, state) do
    _ = Storage.write_atomic(domain, previous)
    _ = apply_previous(domain, previous, state)
    :ok
  end

  defp rollback_update(_domain, nil, _state), do: :ok

  defp rollback_update(domain, previous, state) do
    _ = Storage.write_atomic(domain, previous)
    _ = apply_previous(domain, previous, state)
    :ok
  end

  defp rollback_delete(_domain, nil, _state), do: :ok

  defp rollback_delete(domain, previous, state) do
    _ = Storage.write_atomic(domain, previous)
    _ = apply_previous(domain, previous, state)
    :ok
  end

  defp apply_previous(domain, previous, state) do
    case ensure_server(domain, state, previous) do
      {:ok, pid, _state} -> Server.put(pid, previous)
      _ -> :ok
    end
  end

  defp apply_local_change(:delete, domain, _data, state) do
    {state, _has_server} = server_present(domain, state)

    case Storage.delete(domain) do
      :ok -> {:ok, stop_server(domain, state)}
      :not_found -> {:ok, stop_server(domain, state)}
      {:error, _} = err -> {err, state}
    end
  end

  defp apply_local_change(action, domain, data, state)
       when action in [:create, :update, :put] and is_map(data) do
    case Storage.write_atomic(domain, data) do
      :ok ->
        case ensure_server(domain, state, data) do
          {:ok, _pid, state} -> {:ok, state}
          {:error, _} = err -> {err, state}
          :not_found -> {err_ensure_server(), state}
        end

      {:error, _} = err ->
        {err, state}
    end
  end

  defp apply_local_change(_action, _domain, _data, state),
    do: {{:error, "invalid change payload"}, state}

  defp err_ensure_server, do: {:error, "unable to start zone server"}
end

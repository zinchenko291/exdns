defmodule Models.Dns.Zone.Cluster do
  @moduledoc false

  require Logger

  @spec nodes() :: [node()]
  def nodes do
    Node.list(:visible) ++ Node.list(:hidden)
  end

  @spec other_nodes() :: [node()]
  def other_nodes do
    Enum.reject(nodes(), &(&1 == node()))
  end

  @spec fetch_remote(String.t()) :: {:ok, map()} | :not_found | {:error, String.t()}
  def fetch_remote(domain) when is_binary(domain) do
    other_nodes()
    |> Enum.reduce_while(:not_found, fn node_name, _acc ->
      case :rpc.call(node_name, Models.Dns.Zone.Cache, :fetch_local, [domain]) do
        {:ok, _} = ok ->
          {:halt, ok}

        :not_found ->
          {:cont, :not_found}

        {:error, _} ->
          {:cont, :not_found}

        {:badrpc, reason} ->
          Logger.warning("[Zone.Cluster] rpc fetch failed on #{inspect(node_name)}: #{inspect(reason)}")
          {:cont, :not_found}
      end
    end)
  end

  @spec broadcast_change(atom(), String.t(), map() | nil) ::
          {:ok, [node()]} | {:error, String.t(), [node()]}
  def broadcast_change(action, domain, data \\ nil)
      when is_atom(action) and is_binary(domain) do
    nodes = other_nodes()
    needed = required_acks(length(nodes) + 1)
    Logger.debug("[Zone.Cluster] broadcast #{action} #{domain} nodes=#{length(nodes)} required=#{needed}")

    {acks, ack_nodes} =
      nodes
      |> Enum.map(fn node_name ->
        {node_name,
         Task.async(fn ->
           :rpc.call(node_name, Models.Dns.Zone.Cache, :apply_change, [action, domain, data])
         end)}
      end)
      |> Enum.map(fn {node_name, task} ->
        {node_name, Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill)}
      end)
      |> Enum.reduce({1, []}, fn
        {node_name, {:ok, :ok}}, {acc, ack_nodes} -> {acc + 1, [node_name | ack_nodes]}
        {_node_name, {:ok, {:error, _}}}, acc -> acc
        {_node_name, {:ok, {:badrpc, reason}}}, {acc, ack_nodes} ->
          Logger.warning(
            "[Zone.Cluster] rpc change #{action} failed: #{inspect(reason)}"
          )

          {acc, ack_nodes}

        _other, acc ->
          acc
      end)

    if acks >= needed do
      Logger.debug("[Zone.Cluster] quorum ok acks=#{acks}")
      {:ok, Enum.reverse(ack_nodes)}
    else
      Logger.warning("[Zone.Cluster] quorum failed acks=#{acks} required=#{needed}")
      {:error, "replication quorum not met (acks=#{acks}, required=#{needed})",
       Enum.reverse(ack_nodes)}
    end
  end

  @spec rollback_change(atom(), String.t(), map() | nil, [node()]) :: :ok
  def rollback_change(action, domain, previous, ack_nodes)
      when is_atom(action) and is_binary(domain) and is_list(ack_nodes) do
    {rollback_action, payload} = rollback_payload(action, previous)

    Logger.debug(
      "[Zone.Cluster] rollback #{action} as #{rollback_action} #{domain} nodes=#{length(ack_nodes)}"
    )

    Enum.each(ack_nodes, fn node_name ->
      _ =
        :rpc.call(node_name, Models.Dns.Zone.Cache, :apply_change, [
          rollback_action,
          domain,
          payload
        ])
    end)

    :ok
  end

  defp rollback_payload(:create, _previous), do: {:delete, nil}
  defp rollback_payload(:delete, previous), do: {:put, previous}
  defp rollback_payload(:update, previous), do: {:put, previous}
  defp rollback_payload(:put, previous), do: {:put, previous}
  defp rollback_payload(_action, previous), do: {:put, previous}

  defp required_acks(total_nodes) do
    ratio = Application.get_env(:exdns, :replication_quorum_ratio, 0.5)
    required = Float.ceil(total_nodes * ratio) |> trunc()

    if required < 1 do
      1
    else
      required
    end
  end

  defp timeout_ms do
    Application.get_env(:exdns, :replication_timeout_ms, 2_000)
  end
end

defmodule Models.Dns.Zone.Server do
  @moduledoc false

  use GenServer

  require Logger

  alias Models.Dns.Zone.Storage

  defstruct [:domain, :data]

  @type t :: %__MODULE__{domain: String.t(), data: map()}

  def start_link({domain, data}) when is_binary(domain) and is_map(data) do
    GenServer.start_link(__MODULE__, {domain, data})
  end

  def get(pid), do: GenServer.call(pid, :get)
  def put(pid, data), do: GenServer.call(pid, {:put, data})

  @impl GenServer
  def init({domain, data}) do
    Logger.debug("[Zone.Server] start #{domain}")
    {:ok, %__MODULE__{domain: domain, data: data}}
  end

  @impl GenServer
  def handle_call(:get, _from, %__MODULE__{} = state) do
    Logger.debug("[Zone.Server] get #{state.domain}")
    {:reply, {:ok, state.data}, state}
  end

  def handle_call({:put, data}, _from, %__MODULE__{} = state) when is_map(data) do
    Logger.debug("[Zone.Server] put #{state.domain}")
    case Storage.write_atomic(state.domain, data) do
      :ok -> {:reply, :ok, %{state | data: data}}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:put, _data}, _from, state) do
    {:reply, {:error, "zone data must be a map"}, state}
  end
end

defmodule NetHandler.Udp do
  @moduledoc false
  require Logger
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil)
  end

  @impl GenServer
  def init(_) do
    Logger.info("[NetHandler.Udp]: Starting server")

    port =
      case Application.fetch_env(:exdns, :dns_port) do
        {:ok, port} -> port
        :error -> raise "[NetHandler.Udp]: dns port undefined"
      end

    {:ok, socket} = :gen_udp.open(port, [:binary, :inet, active: true])
    Logger.info("[NetHandler.Udp]: Starting started on port #{port}")
    {:ok, socket}
  end

  @impl GenServer
  def handle_info({:udp, handle_socket, peer_ip, peer_port, packet}, socket) do
    Logger.info("[NetHandler.Udp]: Handle request from #{Tuple.to_list(peer_ip) |> Enum.join(".")}:#{peer_port}")
    Logger.debug("[NetHandler.Udp]: Packet size #{byte_size(packet)} bytes")
    DnsHandler.start_task({:udp, handle_socket, peer_ip, peer_port, packet})
    {:noreply, socket}
  end

  @impl GenServer
  def terminate(_reason, socket) do
    :ok = :gen_udp.close(socket)
    Logger.info("[NetHandler.Udp]: Server stopped")
    :normal
  end
end

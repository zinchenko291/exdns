defmodule Exdns do
  @moduledoc false
  use Application

  require Logger

  @impl Application
  def start(_start_type, _start_args) do
    topologies =
      Application.get_env(:exdns, :cluster_topologies, [])

    Logger.info("[Exdns] starting application")

    children = [
      {Cluster.Supervisor, [topologies, [name: Exdns.ClusterSupervisor]]},
      Models.Dns.Zone.Supervisor,
      Models.Dns.Zone.Cache,
      Models.Dns.Zone.Validator,
      {Bandit,
       plug: Exdns.Http.Router,
       scheme: :http,
       port: Application.fetch_env!(:exdns, :http_port)},
      NetHandler.Udp,
      {Task.Supervisor, name: DnsHandler}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

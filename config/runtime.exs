import Config

defmodule Exdns.RuntimeConfig do
  def fetch_int(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end
    end
  end

  def fetch_float(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      value ->
        case Float.parse(value) do
          {float, _} -> float
          :error -> default
        end
    end
  end
end

if config_env() == :prod do
  config :exdns,
    zones_folder: System.get_env("ZONES_FOLDER", "./zones"),
    dns_port: Exdns.RuntimeConfig.fetch_int("DNS_PORT", 53),
    http_port: Exdns.RuntimeConfig.fetch_int("HTTP_PORT", 8080),
    api_token: System.get_env("API_TOKEN", "changeme"),
    cors_origin: System.get_env("CORS_ORIGIN", "*"),
    replication_quorum_ratio: Exdns.RuntimeConfig.fetch_float("REPLICATION_QUORUM", 0.5),
    replication_timeout_ms: Exdns.RuntimeConfig.fetch_int("REPLICATION_TIMEOUT_MS", 2_000),
    cluster_topologies: []
end

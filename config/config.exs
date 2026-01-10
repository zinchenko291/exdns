import Config

config :exdns,
  zones_folder: "./zones",
  dns_port: 53,
  http_port: 8080,
  api_token: "changeme",
  cors_origin: "*",
  cluster_topologies: [
    local: [
      strategy: Cluster.Strategy.Gossip
    ]
  ],
  replication_quorum_ratio: 0.5,
  replication_timeout_ms: 2_000

import_config "#{Mix.env()}.exs"

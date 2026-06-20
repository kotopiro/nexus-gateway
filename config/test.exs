import Config

config :nexus_gateway, NexusGateway.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :nexus_gateway,
  jwt_secret: "test_secret"

# テストでは常に Stub を使う (外部 DB/NATS 接続なしで決定論的に動かす)
config :nexus_gateway, :data_source, NexusGateway.DataSource.Stub

config :logger, level: :warning

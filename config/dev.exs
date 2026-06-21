import Config

config :nexus_gateway, NexusGateway.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  debug_errors: true,
  check_origin: false,
  watchers: []

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :guild_id, :user_id]

config :logger, level: :debug

# DataSource: PostgreSQL が未設定なら自動で Stub にフォールバックする
# (NexusGateway.DataSource.Postgres 内の with_connection/2 が判定する)
config :nexus_gateway, :data_source, NexusGateway.DataSource.Postgres

# PostgreSQL 接続設定。
# 環境変数 POSTGRES_URL が無い場合は postgres: nil → Application.ex が
# Postgrex プールを起動せず、DataSource.Postgres は自動的に Stub にフォールバックする。
#
# POSTGRES_URL 例: postgresql://nexus:password@localhost:5432/nexus_dev
if url = System.get_env("POSTGRES_URL") do
  uri = URI.parse(url)
  [user, pass] = String.split(uri.userinfo || ":", ":", parts: 2)

  config :nexus_gateway, :postgres,
    hostname: uri.host,
    port: uri.port || 5432,
    username: user,
    password: pass,
    database: String.trim_leading(uri.path || "/nexus_dev", "/"),
    pool_size: 5
end

# NATS 接続設定。環境変数が無ければ NATS なしで起動する。
if url = System.get_env("NATS_URL") do
  config :nexus_gateway, :nats, %{url: url}
end

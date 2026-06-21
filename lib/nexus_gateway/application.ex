defmodule NexusGateway.Application do
  @moduledoc """
  NEXUS Gateway の Supervision Tree。

  PostgreSQL / NATS は設定が無い場合は起動しない (dev/test 環境対応)。
  DataSource.Stub / NATS.Publisher の no-op フォールバックにより、
  これらが起動していなくても nexus-gateway 自体は正常に動作する。
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    version = Application.spec(:nexus_gateway, :vsn) |> to_string()
    Logger.info("Starting NEXUS Gateway v#{version}")

    children =
      [
        # プロセス名前解決レジストリ (GuildProcess の via tuple に必要)
        {Registry, keys: :unique, name: NexusGateway.Registry},
        # user_id → conn_pid レジストリ (MLS Welcome 個別配送等に使用)
        NexusGateway.ConnectionRegistry,
        # セッションストア (ETS ベース, RESUME バッファ)
        NexusGateway.Session.Store,
        # channel_id → guild_id キャッシュ (ETS, TTL 5分)
        NexusGateway.ChannelCache,
        # レート制限 (ETS sliding window)
        NexusGateway.RateLimiter,
        # Guild プロセス動的スーパーバイザ
        NexusGateway.Guild.Supervisor,
        # Phoenix PubSub (ノード内ブロードキャスト)
        {Phoenix.PubSub, name: NexusGateway.PubSub}
      ]
      |> maybe_add_postgres()
      |> maybe_add_nats()
      |> Kernel.++([
        # Phoenix Endpoint (WebSocket 受付、最後に起動)
        NexusGateway.Endpoint
      ])

    opts = [strategy: :one_for_one, name: NexusGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ─── PostgreSQL (任意) ────────────────────────────────────────────────

  defp maybe_add_postgres(children) do
    case Application.get_env(:nexus_gateway, :postgres) do
      nil ->
        Logger.warning("[Application] POSTGRES_URL not set — running with DataSource.Stub")
        children

      opts when is_list(opts) ->
        pool_spec =
          Supervisor.child_spec(
            {Postgrex, Keyword.put(opts, :name, NexusGateway.Repo.Pool)},
            id: NexusGateway.Repo.Pool
          )

        children ++ [pool_spec]
    end
  end

  # ─── NATS (任意) ────────────────────────────────────────────────────

  defp maybe_add_nats(children) do
    case Application.get_env(:nexus_gateway, :nats) do
      nil ->
        Logger.warning("[Application] NATS_URL not set — running without NATS integration")
        children

      %{url: nats_url} ->
        conn_spec = %{
          name: NexusGateway.NATS.Conn,
          connection_settings: [parse_nats_url(nats_url)]
        }

        consumer_spec = %{
          connection_name: NexusGateway.NATS.Conn,
          module: NexusGateway.NATS.Consumer,
          subscription_topics: [
            %{topic: "dispatch.guild.*"},
            %{topic: "dispatch.channel.*"},
            %{topic: "dispatch.user.*"}
          ]
        }

        children ++
          [
            {Gnat.ConnectionSupervisor, conn_spec},
            {Gnat.ConsumerSupervisor, consumer_spec}
          ]
    end
  end

  defp parse_nats_url(url) do
    uri = URI.parse(url)
    %{host: uri.host, port: uri.port}
  end
end

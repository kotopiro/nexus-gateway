defmodule NexusGateway.NATS.Consumer do
  @moduledoc """
  nexus-api などの外部サービスから配送されるイベントを購読する。

  購読 subject (NEXUS_GATEWAY_NWP_v1.md §10.1 準拠):
    dispatch.guild.{guild_id}      → Guild.Process.broadcast/3
    dispatch.channel.{channel_id} → Guild.Process.dispatch/4
    dispatch.user.{user_id}       → ConnectionRegistry.send_to_user/2

  メッセージボディは :erlang.term_to_binary/1 でエンコードされている前提
  (Publisher 側と対になる)。

  NATS 未接続でも nexus-gateway 自体は起動できる。
  接続設定 (nats_url) が無い、または接続に失敗した場合は
  このプロセスが再試行ループに入るだけで、Endpoint や Transport には影響しない。
  """

  use Gnat.Server
  require Logger

  alias NexusGateway.{ConnectionRegistry, Guild}

  @doc """
  Gnat.ConsumerSupervisor から呼ばれるハンドラ。
  request はチャンネルメッセージ。pattern match で subject ごとに分岐する。
  """
  def request(%{topic: "dispatch.guild." <> guild_id, body: body}) do
    handle_event(body, fn event ->
      Guild.Process.broadcast(guild_id, event.t, event.d)
    end)
  end

  def request(%{topic: "dispatch.channel." <> channel_id, body: body}) do
    handle_event(body, fn event ->
      case NexusGateway.ChannelCache.get_or_fetch(channel_id) do
        {:ok, guild_id} ->
          Guild.Process.dispatch(guild_id, channel_id, event.t, event.d)

        {:error, _} ->
          Logger.warning("[NATS.Consumer] dispatch.channel: unknown channel #{channel_id}")
      end
    end)
  end

  def request(%{topic: "dispatch.user." <> user_id, body: body}) do
    handle_event(body, fn event ->
      ConnectionRegistry.send_to_user(user_id, %{op: 0, d: event.d, s: nil, t: event.t})
    end)
  end

  def request(%{topic: topic}) do
    Logger.warning("[NATS.Consumer] Unhandled subject: #{topic}")
    :ok
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp handle_event(body, fun) do
    event = :erlang.binary_to_term(body)
    fun.(event)
    :ok
  rescue
    e ->
      Logger.error("[NATS.Consumer] Failed to process event: #{inspect(e)}")
      :ok
  end
end

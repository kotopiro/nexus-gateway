defmodule NexusGateway.NATS.Publisher do
  @moduledoc """
  nexus-gateway → 他サービス (nexus-api 等) へのイベント発行。

  Subject 命名規則 (NEXUS_GATEWAY_NWP_v1.md §10.1 準拠):
    gateway.message.e2ee.create   E2EE メッセージ永続化依頼
    gateway.mls.commit            MLS Commit 永続化依頼
    gateway.voice.join            ボイス参加 → nexus-media へ
    gateway.voice.leave           ボイス退出

  NATS 未接続の場合は publish を no-op にする (gateway の動作を妨げない)。
  """

  require Logger

  @conn NexusGateway.NATS.Conn

  @doc "NATS に publish する。接続がなければログを出して何もしない。"
  @spec publish(String.t(), map()) :: :ok
  def publish(subject, payload) when is_binary(subject) and is_map(payload) do
    case Process.whereis(@conn) do
      nil ->
        Logger.debug("[NATS.Publisher] not connected, dropping: #{subject}")
        :ok

      pid ->
        body = :erlang.term_to_binary(payload)

        case Gnat.pub(pid, subject, body) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("[NATS.Publisher] publish failed (#{subject}): #{inspect(reason)}")
            :ok
        end
    end
  end

  @doc "E2EE メッセージの永続化依頼"
  @spec publish_e2ee_create(map()) :: :ok
  def publish_e2ee_create(data), do: publish("gateway.message.e2ee.create", data)

  @doc "MLS Commit の永続化依頼"
  @spec publish_mls_commit(map()) :: :ok
  def publish_mls_commit(data), do: publish("gateway.mls.commit", data)

  @doc "ボイスチャンネル参加通知 (nexus-media へ)"
  @spec publish_voice_join(map()) :: :ok
  def publish_voice_join(data), do: publish("gateway.voice.join", data)

  @doc "ボイスチャンネル退出通知"
  @spec publish_voice_leave(map()) :: :ok
  def publish_voice_leave(data), do: publish("gateway.voice.leave", data)
end

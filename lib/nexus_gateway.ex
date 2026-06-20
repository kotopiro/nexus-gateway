defmodule NexusGateway do
  @moduledoc """
  NEXUS Gateway — NWP v1 WebSocket サーバー

  責務:
    - WebSocket 接続管理
    - NWP v1 フレームルーティング
    - Presence 管理 (GuildProcess)
    - E2EE メッセージのルーティング (内容は不明のまま転送)
    - MLS Commit/Welcome の転送

  担当しないこと:
    - メッセージ永続化 (nexus-api)
    - 認証トークン発行 (nexus-api)
    - Push 通知 (nexus-push)
    - ファイルストレージ (nexus-media)
  """
end

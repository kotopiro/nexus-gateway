defmodule NexusGateway.DataSource.Stub do
  @moduledoc """
  DataSource の Stub 実装。

  PostgreSQL に未接続の状態でも nexus-gateway を起動・テストできるようにする。
  config/test.exs のデフォルト。config/dev.exs でも DB 未設定時のフォールバックとして使う。

  挙動:
    - fetch_guild_ids: user_id ごとに決定論的な単一 guild を返す (テストしやすいダミー)
    - fetch_guild_for_channel: channel_id をそのまま guild_id として扱う (1:1 マッピング)
    - fetch_channel_permissions: 常に全権限を許可 (プロトタイプ用、本番では絶対に使わない)
  """

  @behaviour NexusGateway.DataSource

  alias NexusGateway.Permissions

  @impl true
  def fetch_guild_ids(user_id) when is_binary(user_id) do
    {:ok, ["guild_default_#{user_id}"]}
  end

  def fetch_guild_ids(_), do: {:error, :invalid_user_id}

  @impl true
  def fetch_guild_for_channel(channel_id) when is_binary(channel_id) do
    # プロトタイプ: channel_id から guild プレフィックスを推測できない場合は
    # "guild_default_" を冠した固定値を返す (テスト容易性優先)
    {:ok, "guild_default_stub"}
  end

  def fetch_guild_for_channel(_), do: {:error, :not_found}

  @impl true
  def fetch_channel_permissions(_user_id, _channel_id) do
    {:ok, Permissions.all()}
  end

  @impl true
  def fetch_guild_members(guild_id) when is_binary(guild_id) do
    # プロトタイプ用の決定論的なダミーメンバー (テスト容易性優先)。
    # 本番では DataSource.Postgres が guild_members テーブルから取得する。
    members =
      for n <- 1..3 do
        %{"user_id" => "#{guild_id}_member_#{n}", "username" => "stub_user_#{n}"}
      end

    {:ok, members}
  end

  def fetch_guild_members(_), do: {:error, :invalid_guild_id}
end

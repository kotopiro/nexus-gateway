defmodule NexusGateway.DataSource do
  @moduledoc """
  外部データ (PostgreSQL等) へのアクセスを抽象化する behavior。

  transport.ex はこの behavior 経由でのみ外部データを取得する。
  実装の差し替え (Postgres / Stub / 将来の REST 経由) は
  config :nexus_gateway, :data_source で切り替える。

  config/dev.exs:  data_source: NexusGateway.DataSource.Postgres
  config/test.exs: data_source: NexusGateway.DataSource.Stub
  """

  @doc "ユーザーが参加している guild_id 一覧を返す"
  @callback fetch_guild_ids(user_id :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc "channel_id が所属する guild_id を返す"
  @callback fetch_guild_for_channel(channel_id :: String.t()) ::
              {:ok, String.t()} | {:error, :not_found}

  @doc "ユーザーがチャンネルでアクションを実行する権限を持つか確認する"
  @callback fetch_channel_permissions(user_id :: String.t(), channel_id :: String.t()) ::
              {:ok, NexusGateway.Permissions.permission_set()} | {:error, term()}

  @doc """
  guild に所属するメンバー一覧を返す (REQUEST_MEMBERS / GUILD_MEMBERS_CHUNK 用)。

  各メンバーは最低限 "user_id" を含む map。実装によっては username 等も付与してよい。
  E2EE 原則: メンバー情報は公開メタデータのみ (公開鍵 Blob 等は含めない)。
  """
  @callback fetch_guild_members(guild_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "現在設定されている DataSource 実装モジュールを返す"
  def impl do
    Application.get_env(:nexus_gateway, :data_source, NexusGateway.DataSource.Stub)
  end

  @doc "ユーザーが参加している guild_id 一覧 (現在の実装経由)"
  def fetch_guild_ids(user_id), do: impl().fetch_guild_ids(user_id)

  @doc "channel_id が所属する guild_id (現在の実装経由)"
  def fetch_guild_for_channel(channel_id), do: impl().fetch_guild_for_channel(channel_id)

  @doc "チャンネル権限 (現在の実装経由)"
  def fetch_channel_permissions(user_id, channel_id),
    do: impl().fetch_channel_permissions(user_id, channel_id)

  @doc "guild のメンバー一覧 (現在の実装経由)"
  def fetch_guild_members(guild_id), do: impl().fetch_guild_members(guild_id)
end

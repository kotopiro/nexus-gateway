defmodule NexusGateway.DataSource.Postgres do
  @moduledoc """
  DataSource の PostgreSQL 実装。

  接続プール: NexusGateway.Repo.Pool (Postgrex.start_link/1 で起動、application.ex で管理)
  接続設定がない場合は Stub にフォールバックする (起動を妨げない)。

  スキーマ前提 (NEXUS_ARCHITECTURE_v0.2.md 7.3 参照):
    guild_members(user_id, guild_id)
    channels(id, guild_id)
    member_roles(user_id, guild_id, role_id)
    roles(id, guild_id, permissions)
  """

  @behaviour NexusGateway.DataSource

  require Logger

  alias NexusGateway.Permissions

  @pool NexusGateway.Repo.Pool

  @impl true
  def fetch_guild_ids(user_id) do
    query = "SELECT guild_id FROM guild_members WHERE user_id = $1"

    with_connection(
      fn conn ->
        case Postgrex.query(conn, query, [user_id]) do
          {:ok, %Postgrex.Result{rows: rows}} ->
            {:ok, Enum.map(rows, fn [guild_id] -> guild_id end)}

          {:error, reason} ->
            Logger.error("[DataSource.Postgres] fetch_guild_ids failed: #{inspect(reason)}")
            {:error, reason}
        end
      end,
      fn -> NexusGateway.DataSource.Stub.fetch_guild_ids(user_id) end
    )
  end

  @impl true
  def fetch_guild_for_channel(channel_id) do
    query = "SELECT guild_id FROM channels WHERE id = $1"

    with_connection(
      fn conn ->
        case Postgrex.query(conn, query, [channel_id]) do
          {:ok, %Postgrex.Result{rows: [[guild_id]]}} ->
            {:ok, guild_id}

          {:ok, %Postgrex.Result{rows: []}} ->
            {:error, :not_found}

          {:error, reason} ->
            Logger.error(
              "[DataSource.Postgres] fetch_guild_for_channel failed: #{inspect(reason)}"
            )

            {:error, reason}
        end
      end,
      fn -> NexusGateway.DataSource.Stub.fetch_guild_for_channel(channel_id) end
    )
  end

  @impl true
  def fetch_channel_permissions(user_id, channel_id) do
    query = """
    SELECT COALESCE(BIT_OR(r.permissions), 0)
    FROM channels c
    JOIN member_roles mr ON mr.guild_id = c.guild_id AND mr.user_id = $1
    JOIN roles r ON r.id = mr.role_id
    WHERE c.id = $2
    """

    with_connection(
      fn conn ->
        case Postgrex.query(conn, query, [user_id, channel_id]) do
          {:ok, %Postgrex.Result{rows: [[bits]]}} ->
            {:ok, Permissions.from_bits(bits)}

          {:ok, %Postgrex.Result{rows: []}} ->
            {:ok, Permissions.none()}

          {:error, reason} ->
            Logger.error(
              "[DataSource.Postgres] fetch_channel_permissions failed: #{inspect(reason)}"
            )

            {:error, reason}
        end
      end,
      fn -> NexusGateway.DataSource.Stub.fetch_channel_permissions(user_id, channel_id) end
    )
  end

  @impl true
  def fetch_guild_members(guild_id) do
    # 公開メタデータのみ取得する (E2EE 原則: 公開鍵 Blob 等は含めない)。
    query = """
    SELECT gm.user_id, u.username
    FROM guild_members gm
    LEFT JOIN users u ON u.id = gm.user_id
    WHERE gm.guild_id = $1
    """

    with_connection(
      fn conn ->
        case Postgrex.query(conn, query, [guild_id]) do
          {:ok, %Postgrex.Result{rows: rows}} ->
            members =
              Enum.map(rows, fn [user_id, username] ->
                %{"user_id" => user_id, "username" => username}
              end)

            {:ok, members}

          {:error, reason} ->
            Logger.error("[DataSource.Postgres] fetch_guild_members failed: #{inspect(reason)}")
            {:error, reason}
        end
      end,
      fn -> NexusGateway.DataSource.Stub.fetch_guild_members(guild_id) end
    )
  end

  # ─── Private ────────────────────────────────────────────────────────

  # 接続プールが起動していない場合 (DB未設定の dev 環境) は Stub にフォールバックする。
  # これにより PostgreSQL なしでも nexus-gateway は起動・動作できる。
  defp with_connection(query_fun, fallback_fun) do
    case Process.whereis(@pool) do
      nil ->
        Logger.warning("[DataSource.Postgres] Pool not running, falling back to Stub")
        fallback_fun.()

      pid when is_pid(pid) ->
        query_fun.(pid)
    end
  end
end

defmodule NexusGateway.DataSource.Postgres do
  @moduledoc """
  DataSource の PostgreSQL 実装。

  接続プール: NexusGateway.Repo.Pool (Postgrex.start_link/1 で起動、application.ex で管理)
  接続設定がない場合は Stub にフォールバックする (起動を妨げない)。

  スキーマ: migrations/ 配下の golang-migrate 互換マイグレーションを参照。
    guild_members(user_id, guild_id)
    channels(id, guild_id)
    member_roles(user_id, guild_id, role_id)
    roles(id, guild_id, permissions)
    users(id, username)

  ★ UUID の扱いについて (重要) ★
    Postgrex は素の状態では UUID カラムを「文字列」として送受信できない。
    内部の Postgrex.Extensions.UUID は厳密に「16バイトの生バイナリ」のみを
    受け付け、`"11111111-1111-..."` のようなダッシュ付き文字列を渡すと
    DBConnection.EncodeError で例外になる (実機検証で確認済みの実バグ)。

    一方、JWT の `sub` クレームや WebSocket 経由のクライアント入力は
    常に文字列形式の UUID として届く。そのため、このモジュールの境界で
    必ず文字列 ⇄ バイナリの変換を行う:
      - クエリパラメータに渡す前: uuid_to_binary/1 で文字列→16バイト
      - クエリ結果から取り出した後: uuid_to_string/1 で16バイト→文字列
    呼び出し元 (transport.ex, ChannelCache 等) は常に文字列形式の UUID を
    扱う前提を変えない。バイナリ変換はこのモジュール内に閉じ込める。
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
        with {:ok, user_id_bin} <- uuid_to_binary(user_id),
             {:ok, %Postgrex.Result{rows: rows}} <- Postgrex.query(conn, query, [user_id_bin]) do
          {:ok, Enum.map(rows, fn [guild_id_bin] -> uuid_to_string(guild_id_bin) end)}
        else
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
        with {:ok, channel_id_bin} <- uuid_to_binary(channel_id),
             {:ok, result} <- Postgrex.query(conn, query, [channel_id_bin]) do
          case result.rows do
            [[guild_id_bin]] -> {:ok, uuid_to_string(guild_id_bin)}
            [] -> {:error, :not_found}
          end
        else
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
        with {:ok, user_id_bin} <- uuid_to_binary(user_id),
             {:ok, channel_id_bin} <- uuid_to_binary(channel_id),
             {:ok, result} <- Postgrex.query(conn, query, [user_id_bin, channel_id_bin]) do
          case result.rows do
            [[bits]] -> {:ok, Permissions.from_bits(bits)}
            [] -> {:ok, Permissions.none()}
          end
        else
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
        with {:ok, guild_id_bin} <- uuid_to_binary(guild_id),
             {:ok, %Postgrex.Result{rows: rows}} <- Postgrex.query(conn, query, [guild_id_bin]) do
          members =
            Enum.map(rows, fn [user_id_bin, username] ->
              %{"user_id" => uuid_to_string(user_id_bin), "username" => username}
            end)

          {:ok, members}
        else
          {:error, reason} ->
            Logger.error("[DataSource.Postgres] fetch_guild_members failed: #{inspect(reason)}")
            {:error, reason}
        end
      end,
      fn -> NexusGateway.DataSource.Stub.fetch_guild_members(guild_id) end
    )
  end

  # ─── UUID 変換 (Private) ─────────────────────────────────────────────

  # "11111111-1111-1111-1111-111111111111" -> <<16バイトの生バイナリ>>
  defp uuid_to_binary(uuid_string) when is_binary(uuid_string) do
    hex = String.replace(uuid_string, "-", "")

    case byte_size(hex) do
      32 ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, bin} -> {:ok, bin}
          :error -> {:error, {:invalid_uuid, uuid_string}}
        end

      _ ->
        {:error, {:invalid_uuid, uuid_string}}
    end
  end

  defp uuid_to_binary(other), do: {:error, {:invalid_uuid, other}}

  # <<16バイトの生バイナリ>> -> "11111111-1111-1111-1111-111111111111"
  defp uuid_to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> List.to_string()
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

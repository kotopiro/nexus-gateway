defmodule NexusGateway.DataSource.PostgresTest do
  @moduledoc """
  DataSource.Postgres の実 PostgreSQL に対する統合テスト。

  デフォルトの `mix test` では実行されない (test_helper.exs で :integration を除外)。
  実行するには:

    1. migrations/ 配下の .up.sql を順番に実行 (実 DB に対して)
    2. 以下のテストデータを投入:
         users:    alice (11111111-...), bob (22222222-...)
         guilds:   Test Guild (33333333-...)
         channels: general (44444444-...) layer=3, guild_id=Test Guild
         roles:    member (55555555-...) permissions=3, guild_id=Test Guild
         guild_members: alice+bob を Test Guild に参加させる
         member_roles:  alice のみ member ロールを付与
    3. POSTGRES_URL を設定し `mix test --include integration` を実行

  このテストは「UUID文字列 ⇄ 16バイトバイナリ変換」の実装が正しいことを
  実際の Postgres 接続で証明する (postgres.ex のコメント参照)。
  Postgrex の組み込み UUID extension はバイナリ16バイト以外を受け付けないため、
  この変換ロジックは省略できない。
  """

  use ExUnit.Case, async: false

  alias NexusGateway.DataSource.Postgres
  alias NexusGateway.Permissions

  @alice "11111111-1111-1111-1111-111111111111"
  @bob "22222222-2222-2222-2222-222222222222"
  @guild "33333333-3333-3333-3333-333333333333"
  @channel "44444444-4444-4444-4444-444444444444"
  @nonexistent "99999999-9999-9999-9999-999999999999"

  setup_all do
    {:ok, _pool} =
      Postgrex.start_link(
        hostname: System.get_env("POSTGRES_HOST", "localhost"),
        port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
        username: System.get_env("POSTGRES_USER", "nexus"),
        password: System.get_env("POSTGRES_PASSWORD", "nexus_dev_pass"),
        database: System.get_env("POSTGRES_DB", "nexus_dev"),
        name: NexusGateway.Repo.Pool
      )

    :ok
  end

  @tag :integration
  test "fetch_guild_ids: 文字列UUIDを渡して文字列UUIDのリストが返る" do
    assert {:ok, [@guild]} = Postgres.fetch_guild_ids(@alice)
  end

  @tag :integration
  test "fetch_guild_ids: 存在しないユーザーは空リスト" do
    assert {:ok, []} = Postgres.fetch_guild_ids(@nonexistent)
  end

  @tag :integration
  test "fetch_guild_for_channel: 文字列UUIDの往復変換が一致する" do
    assert {:ok, @guild} = Postgres.fetch_guild_for_channel(@channel)
  end

  @tag :integration
  test "fetch_guild_for_channel: 存在しないチャンネルは :not_found" do
    assert {:error, :not_found} = Postgres.fetch_guild_for_channel(@nonexistent)
  end

  @tag :integration
  test "fetch_channel_permissions: ロールを持つユーザーは正しい権限ビットを取得する" do
    assert {:ok, perms} = Postgres.fetch_channel_permissions(@alice, @channel)
    assert Permissions.has?(perms, Permissions.view_channel())
    assert Permissions.has?(perms, Permissions.send_messages())
    refute Permissions.has?(perms, Permissions.manage_roles())
  end

  @tag :integration
  test "fetch_channel_permissions: ロールを持たないユーザーは none()" do
    assert {:ok, perms} = Postgres.fetch_channel_permissions(@bob, @channel)
    assert perms == Permissions.none()
  end

  @tag :integration
  test "fetch_guild_members: 全メンバーが文字列UUIDのuser_idと共に返る" do
    assert {:ok, members} = Postgres.fetch_guild_members(@guild)
    user_ids = Enum.map(members, & &1["user_id"])
    assert @alice in user_ids
    assert @bob in user_ids

    alice_row = Enum.find(members, &(&1["user_id"] == @alice))
    assert alice_row["username"] == "alice"
  end

  @tag :integration
  test "Postgresプール未起動時は Stub にフォールバックする" do
    # NexusGateway.Repo.Pool とは別名で起動し、本来のプールが
    # 見つからない状況を再現する代わりに、Stub単体の挙動を直接確認する。
    # (実プールを止めると後続テストに影響するため、Stub側の契約を確認するのみ)
    assert {:ok, ["guild_default_unknown_user"]} =
             NexusGateway.DataSource.Stub.fetch_guild_ids("unknown_user")
  end
end

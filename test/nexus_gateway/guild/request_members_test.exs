defmodule NexusGateway.Guild.RequestMembersTest do
  use ExUnit.Case, async: true

  alias NexusGateway.Guild.{Process, Supervisor}

  # DataSource.Stub.fetch_guild_members/1 は guild_id をもとに
  # "#{guild_id}_member_1" 〜 "#{guild_id}_member_3" の3人を返す (決定論的)。

  setup do
    guild_id = "guild_rm_#{System.unique_integer([:positive])}"
    :ok = Supervisor.ensure_started(guild_id)
    {:ok, guild_id: guild_id}
  end

  test "REQUEST_MEMBERS は要求元にのみ GUILD_MEMBERS_CHUNK を返す (broadcast しない)",
       %{guild_id: gid} do
    other_pid = spawn(fn -> :timer.sleep(500) end)
    Process.join(gid, "observer", other_pid)

    Process.request_members(gid, self())

    assert_receive {:dispatch, event}, 500
    assert event.t == "GUILD_MEMBERS_CHUNK"
    assert event.d["guild_id"] == gid
    assert length(event.d["members"]) == 3

    # observer (別プロセス) には届かない
    refute_receive {:dispatch, %{t: "GUILD_MEMBERS_CHUNK"}}, 200
  end

  test "chunk_index / chunk_count が正しく付与される", %{guild_id: gid} do
    Process.request_members(gid, self())

    assert_receive {:dispatch, event}, 500
    assert event.d["chunk_index"] == 0
    assert event.d["chunk_count"] == 1
  end

  test "query フィルタで前方一致のメンバーのみ返る", %{guild_id: gid} do
    Process.request_members(gid, self(), %{
      "query" => "#{gid}_member_1"
    })

    assert_receive {:dispatch, event}, 500
    assert length(event.d["members"]) == 1
    assert hd(event.d["members"])["user_id"] == "#{gid}_member_1"
  end

  test "query が空文字なら全件返る", %{guild_id: gid} do
    Process.request_members(gid, self(), %{"query" => ""})

    assert_receive {:dispatch, event}, 500
    assert length(event.d["members"]) == 3
  end

  test "limit で件数を絞れる", %{guild_id: gid} do
    Process.request_members(gid, self(), %{"limit" => 1})

    assert_receive {:dispatch, event}, 500
    assert length(event.d["members"]) == 1
  end

  test "limit が nil なら全件返る", %{guild_id: gid} do
    Process.request_members(gid, self(), %{"limit" => nil})

    assert_receive {:dispatch, event}, 500
    assert length(event.d["members"]) == 3
  end

  test "オンライン中のメンバーには status: online が付与される", %{guild_id: gid} do
    member_id = "#{gid}_member_1"
    Process.join(gid, member_id, self())

    # join 時の PRESENCE_UPDATE を読み捨てる
    assert_receive {:dispatch, %{t: "PRESENCE_UPDATE"}}, 500

    Process.request_members(gid, self())
    assert_receive {:dispatch, event}, 500

    member = Enum.find(event.d["members"], &(&1["user_id"] == member_id))
    assert member["status"] == "online"

    other = Enum.find(event.d["members"], &(&1["user_id"] != member_id))
    assert other["status"] == "offline"
  end

  test "0件マッチでも終端チャンクが1件届く (クライアントを待たせない)", %{guild_id: gid} do
    Process.request_members(gid, self(), %{
      "query" => "no_such_user_prefix"
    })

    assert_receive {:dispatch, event}, 500
    assert event.d["members"] == []
    assert event.d["chunk_count"] == 1
  end
end

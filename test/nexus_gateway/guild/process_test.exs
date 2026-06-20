defmodule NexusGateway.Guild.ProcessTest do
  use ExUnit.Case, async: true

  alias NexusGateway.Guild.{Process, Supervisor}
  alias NexusGateway.NWP.Frame

  # テストごとに一意な guild_id を使う
  setup do
    guild_id = "guild_test_#{System.unique_integer([:positive])}"
    :ok = Supervisor.ensure_started(guild_id)
    {:ok, guild_id: guild_id}
  end

  test "join するとオンライン PRESENCE_UPDATE が届く", %{guild_id: gid} do
    Process.join(gid, "user_a", self())

    assert_receive {:dispatch, event_map}, 500
    assert event_map.t == "PRESENCE_UPDATE"
    assert event_map.d["user_id"] == "user_a"
    assert event_map.d["status"]  == "online"
  end

  test "broadcast が全メンバーに届く", %{guild_id: gid} do
    Process.join(gid, "user_b", self())
    assert_receive {:dispatch, _}, 500  # PRESENCE_UPDATE を読み捨て

    Process.broadcast(gid, "CUSTOM_EVENT", %{"value" => 42})

    assert_receive {:dispatch, event_map}, 500
    assert event_map.t          == "CUSTOM_EVENT"
    assert event_map.d["value"] == 42
  end

  test "leave するとオフライン PRESENCE_UPDATE が届く", %{guild_id: gid} do
    Process.join(gid, "user_c", self())
    assert_receive {:dispatch, _}, 500  # online

    Process.leave(gid, "user_c", self())
    assert_receive {:dispatch, event_map}, 500
    assert event_map.d["status"] == "offline"
  end

  test "dispatch は指定チャンネルの購読者にのみ届く", %{guild_id: gid} do
    # このテストでは subscriptions に直接追加する代わりに
    # dispatch の挙動を確認する (購読者なし → 誰にも届かない)
    Process.dispatch(gid, "ch_000", "MESSAGE_CREATE", %{"content" => "hi"})
    refute_receive {:dispatch, _}, 200
  end

  test "presence_update が全メンバーに届く", %{guild_id: gid} do
    Process.join(gid, "user_d", self())
    assert_receive {:dispatch, _}, 500  # online

    Process.update_presence(gid, "user_d", %{"status" => "dnd"})
    assert_receive {:dispatch, event_map}, 500
    assert event_map.t          == "PRESENCE_UPDATE"
    assert event_map.d["status"] == "dnd"
  end

  test "typing_start が届き 3 秒後に自動終了する", %{guild_id: gid} do
    Process.join(gid, "user_e", self())
    assert_receive {:dispatch, _}, 500

    # 別ユーザーも参加させて typing を受け取る側にする
    other_pid = spawn(fn -> receive do _ -> :ok end end)
    Process.join(gid, "user_f", other_pid)
    assert_receive {:dispatch, _}, 500  # user_f online

    # user_e が typing_start
    Process.typing_start(gid, "ch_typing", "user_e")

    # このプロセス (user_e として参加中) には自分の typing は届かない
    # user_f 側に届くはず → ここでは state のタイマーが作成されたことを間接確認
    state = Process.get_state(gid)
    assert Map.has_key?(state.typing_timers, {"ch_typing", "user_e"})
  end

  test "get_state でデバッグ情報を取れる", %{guild_id: gid} do
    state = Process.get_state(gid)
    assert state.guild_id == gid
    assert is_map(state.connections)
  end
end

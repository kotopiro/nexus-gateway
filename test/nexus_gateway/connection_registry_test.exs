defmodule NexusGateway.ConnectionRegistryTest do
  use ExUnit.Case, async: true

  alias NexusGateway.ConnectionRegistry

  defp unique_user, do: "user_#{System.unique_integer([:positive])}"

  describe "register/1 and lookup/1" do
    test "register した自分の pid が lookup で返る" do
      user_id = unique_user()
      ConnectionRegistry.register(user_id)

      assert ConnectionRegistry.lookup(user_id) == [self()]
    end

    test "未登録ユーザーは空リスト" do
      assert ConnectionRegistry.lookup(unique_user()) == []
    end

    test "同一ユーザーが複数プロセスから登録できる (複数デバイス)" do
      user_id = unique_user()
      parent  = self()

      ConnectionRegistry.register(user_id)

      task =
        Task.async(fn ->
          ConnectionRegistry.register(user_id)
          send(parent, :registered)
          # プロセスを生存させたままlookupを確認できるようにする
          Process.sleep(200)
        end)

      assert_receive :registered, 500

      pids = ConnectionRegistry.lookup(user_id)
      assert length(pids) == 2
      assert self() in pids

      Task.await(task)
    end
  end

  describe "unregister/1" do
    test "解除後は lookup に出てこない" do
      user_id = unique_user()
      ConnectionRegistry.register(user_id)
      assert ConnectionRegistry.lookup(user_id) == [self()]

      ConnectionRegistry.unregister(user_id)
      assert ConnectionRegistry.lookup(user_id) == []
    end
  end

  describe "online?/1" do
    test "登録中なら true" do
      user_id = unique_user()
      ConnectionRegistry.register(user_id)
      assert ConnectionRegistry.online?(user_id) == true
    end

    test "未登録なら false" do
      assert ConnectionRegistry.online?(unique_user()) == false
    end
  end

  describe "send_to_user/2" do
    test "登録済みの全プロセスにイベントが送られる" do
      user_id = unique_user()
      ConnectionRegistry.register(user_id)

      event = %{op: 0, d: %{"hello" => "world"}, s: nil, t: "TEST_EVENT"}
      ConnectionRegistry.send_to_user(user_id, event)

      assert_receive {:dispatch, ^event}, 500
    end

    test "未登録ユーザーに送っても落ちない" do
      assert :ok = ConnectionRegistry.send_to_user(unique_user(), %{op: 0})
    end
  end
end

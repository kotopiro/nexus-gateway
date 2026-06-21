defmodule NexusGateway.DataSource.StubTest do
  use ExUnit.Case, async: true

  alias NexusGateway.DataSource.Stub

  describe "fetch_guild_members/1" do
    test "guild_id ごとに決定論的な3人のメンバーを返す" do
      assert {:ok, members} = Stub.fetch_guild_members("guild_x")
      assert length(members) == 3

      assert Enum.map(members, & &1["user_id"]) == [
               "guild_x_member_1",
               "guild_x_member_2",
               "guild_x_member_3"
             ]
    end

    test "各メンバーは user_id と username を持つ" do
      {:ok, [member | _]} = Stub.fetch_guild_members("guild_y")
      assert member["user_id"]
      assert member["username"]
    end

    test "guild_id が文字列でなければエラー" do
      assert {:error, :invalid_guild_id} = Stub.fetch_guild_members(123)
      assert {:error, :invalid_guild_id} = Stub.fetch_guild_members(nil)
    end

    test "異なる guild_id は異なるメンバーを返す (混ざらない)" do
      {:ok, members_a} = Stub.fetch_guild_members("guild_a")
      {:ok, members_b} = Stub.fetch_guild_members("guild_b")

      ids_a = Enum.map(members_a, & &1["user_id"])
      ids_b = Enum.map(members_b, & &1["user_id"])

      assert Enum.all?(ids_a, &String.starts_with?(&1, "guild_a"))
      assert Enum.all?(ids_b, &String.starts_with?(&1, "guild_b"))
    end
  end

  describe "fetch_guild_ids/1" do
    test "user_id ごとに単一の guild を返す" do
      assert {:ok, ["guild_default_alice"]} = Stub.fetch_guild_ids("alice")
    end
  end

  describe "fetch_channel_permissions/2" do
    test "常に全権限を返す (プロトタイプ用フォールバック)" do
      assert {:ok, perms} = Stub.fetch_channel_permissions("u", "c")
      assert perms == NexusGateway.Permissions.all()
    end
  end
end

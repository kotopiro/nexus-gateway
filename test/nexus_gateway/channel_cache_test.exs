defmodule NexusGateway.ChannelCacheTest do
  use ExUnit.Case, async: false

  alias NexusGateway.ChannelCache

  defp unique_id, do: "ch_#{System.unique_integer([:positive])}"

  describe "get/1 and put/2" do
    test "未登録のキーは :miss を返す" do
      assert :miss == ChannelCache.get(unique_id())
    end

    test "put したキーは get できる" do
      channel_id = unique_id()
      guild_id   = "guild_xxx"

      ChannelCache.put(channel_id, guild_id)
      assert {:ok, ^guild_id} = ChannelCache.get(channel_id)
    end
  end

  describe "invalidate/1" do
    test "破棄したキーは :miss になる" do
      channel_id = unique_id()
      ChannelCache.put(channel_id, "guild_yyy")
      assert {:ok, _} = ChannelCache.get(channel_id)

      ChannelCache.invalidate(channel_id)
      assert :miss == ChannelCache.get(channel_id)
    end
  end

  describe "get_or_fetch/1" do
    test "キャッシュミス時は DataSource (Stub) から取得してキャッシュする" do
      channel_id = unique_id()

      # Stub.fetch_guild_for_channel は常に "guild_default_stub" を返す
      assert {:ok, "guild_default_stub"} = ChannelCache.get_or_fetch(channel_id)

      # 2回目はキャッシュから取得される (同じ結果)
      assert {:ok, "guild_default_stub"} = ChannelCache.get_or_fetch(channel_id)
      assert {:ok, "guild_default_stub"} = ChannelCache.get(channel_id)
    end
  end
end

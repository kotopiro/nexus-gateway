defmodule NexusGateway.RateLimiterTest do
  use ExUnit.Case, async: false

  alias NexusGateway.RateLimiter

  # RateLimiter は named ETS table を使うシングルトン GenServer。
  # Application 起動時に立ち上がっているはずなので、ここでは再利用する。
  # テストごとに一意な ID を使うことでテスト間の干渉を避ける。

  defp unique_id, do: "test_#{System.unique_integer([:positive])}"

  describe "check_global/1" do
    test "制限内なら :ok を返す" do
      id = unique_id()
      for _ <- 1..50, do: assert(:ok == RateLimiter.check_global(id))
    end

    test "120件を超えると rate_limited になる" do
      id = unique_id()
      results = for _ <- 1..125, do: RateLimiter.check_global(id)
      assert Enum.any?(results, &(&1 == {:error, :rate_limited}))
    end

    test "別の id には影響しない" do
      id_a = unique_id()
      id_b = unique_id()

      for _ <- 1..125, do: RateLimiter.check_global(id_a)
      assert :ok == RateLimiter.check_global(id_b)
    end
  end

  describe "check_typing/2" do
    test "同一 user+channel で 1件/3秒を超えると制限される" do
      user_id = unique_id()
      channel_id = unique_id()

      assert :ok = RateLimiter.check_typing(user_id, channel_id)
      assert {:error, :rate_limited} = RateLimiter.check_typing(user_id, channel_id)
    end

    test "異なるチャンネルなら制限されない" do
      user_id = unique_id()

      assert :ok = RateLimiter.check_typing(user_id, "ch_a_#{user_id}")
      assert :ok = RateLimiter.check_typing(user_id, "ch_b_#{user_id}")
    end
  end

  describe "check_e2ee/1" do
    test "burst制限内なら :ok" do
      id = unique_id()
      for _ <- 1..5, do: assert(:ok == RateLimiter.check_e2ee(id))
    end

    test "sustained制限(5件/秒)を超えると rate_limited" do
      id = unique_id()
      results = for _ <- 1..10, do: RateLimiter.check_e2ee(id)
      assert Enum.any?(results, &(&1 == {:error, :rate_limited}))
    end
  end
end

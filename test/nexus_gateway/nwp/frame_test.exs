defmodule NexusGateway.NWP.FrameTest do
  use ExUnit.Case, async: true

  alias NexusGateway.NWP.Frame

  describe "decode/1" do
    test "HEARTBEAT フレームをデコードする" do
      binary = Frame.encode(%{op: 1, d: nil, s: nil, t: nil})
      assert {:ok, frame} = Frame.decode(binary)
      assert frame.op == 1
      assert frame.d  == nil
      assert frame.s  == nil
      assert frame.t  == nil
    end

    test "DISPATCH フレームをデコードする" do
      binary = Frame.encode(%{
        op: 0,
        d:  %{"channel_id" => "ch_123", "content" => "hello"},
        s:  42,
        t:  "MESSAGE_CREATE",
      })
      assert {:ok, frame} = Frame.decode(binary)
      assert frame.op         == 0
      assert frame.s          == 42
      assert frame.t          == "MESSAGE_CREATE"
      assert frame.d["content"] == "hello"
    end

    test "E2EE payload (binary) をそのまま保持する" do
      payload = :crypto.strong_rand_bytes(64)
      binary  = Frame.encode(%{
        op: 13,
        d:  %{"payload" => payload, "channel_id" => "ch_e2ee"},
        s:  nil,
        t:  nil,
      })
      assert {:ok, frame} = Frame.decode(binary)
      assert frame.d["payload"] == payload
    end

    test "op フィールドがなければ :missing_op" do
      binary = Msgpax.pack!(%{"d" => nil, "s" => nil, "t" => nil}, iodata: false)
      assert {:error, :missing_op} = Frame.decode(binary)
    end

    test "無効な MessagePack はエラー" do
      assert {:error, _} = Frame.decode(<<0xFF, 0xFE, 0xFD>>)
    end

    test "4MB を超えるフレームはエラー" do
      huge = :binary.copy(<<0>>, 4 * 1024 * 1024 + 1)
      assert {:error, :frame_too_large} = Frame.decode(huge)
    end
  end

  describe "encode/1" do
    test "atom キーでエンコードできる" do
      frame = %{op: 0, d: %{"x" => 1}, s: 1, t: "EVT"}
      binary = Frame.encode(frame)
      assert is_binary(binary)
      assert {:ok, decoded} = Frame.decode(binary)
      assert decoded.op == 0
    end

    test "エンコード→デコードのラウンドトリップ" do
      original = %{op: 9, d: %{"status" => "idle"}, s: nil, t: nil}
      result   = original |> Frame.encode() |> Frame.decode()
      assert {:ok, decoded} = result
      assert decoded.op              == 9
      assert decoded.d["status"]     == "idle"
    end
  end

  describe "event/2" do
    test "DISPATCH フレームの map を返す" do
      evt = Frame.event("TYPING_START", %{"user_id" => "u1"})
      assert evt.op == 0
      assert evt.t  == "TYPING_START"
      assert evt.d["user_id"] == "u1"
    end
  end
end

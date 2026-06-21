defmodule NexusGateway.TestHelpers do
  @moduledoc "テストユーティリティ"

  alias NexusGateway.Auth
  alias NexusGateway.NWP.Frame

  @doc "テスト用 JWT トークンを発行する"
  def generate_token(user_id \\ "test_user", username \\ "TestUser") do
    {:ok, token, _claims} = Auth.generate_token(user_id, username)
    token
  end

  @doc "フレームをデコードして内容を返す"
  def decode(binary) do
    {:ok, frame} = Frame.decode(binary)
    frame
  end

  @doc "IDENTIFY フレームを組み立てる"
  def identify_frame(token, intents \\ 0) do
    Frame.encode(%{
      op: 3,
      d: %{"token" => token, "intents" => intents},
      s: nil,
      t: nil
    })
  end

  @doc "HEARTBEAT フレームを組み立てる"
  def heartbeat_frame do
    Frame.encode(%{op: 1, d: nil, s: nil, t: nil})
  end
end

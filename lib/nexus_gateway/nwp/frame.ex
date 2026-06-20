defmodule NexusGateway.NWP.Frame do
  @moduledoc """
  NWP v1 フレームの MessagePack エンコード/デコード

  フレーム構造:
    op: uint8        - Opcode (必須)
    d:  any          - Payload (Opcode に依存)
    s:  uint64|nil   - シーケンス番号 (DISPATCH のみ)
    t:  string|nil   - イベント名 (DISPATCH のみ)

  内部表現: atom キー
  MessagePack: string キー (相互変換は encode/decode が担当)
  """

  @type t :: %{
    op: non_neg_integer(),
    d:  term(),
    s:  non_neg_integer() | nil,
    t:  String.t() | nil,
  }

  @max_size 4 * 1024 * 1024  # 4 MB

  # ─── Decode ─────────────────────────────────────────────────────────

  @doc "バイナリ (MessagePack) → フレーム map"
  @spec decode(binary()) :: {:ok, t()} | {:error, atom() | term()}
  def decode(binary) when byte_size(binary) > @max_size do
    {:error, :frame_too_large}
  end

  def decode(binary) when is_binary(binary) do
    case Msgpax.unpack(binary) do
      {:ok, %{"op" => op} = raw} when is_integer(op) ->
        {:ok, %{
          op: op,
          d:  Map.get(raw, "d"),
          s:  Map.get(raw, "s"),
          t:  Map.get(raw, "t"),
        }}

      {:ok, _} ->
        {:error, :missing_op}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_), do: {:error, :not_binary}

  # ─── Encode ─────────────────────────────────────────────────────────

  @doc "フレーム map → バイナリ (MessagePack)"
  @spec encode(t() | map()) :: binary()
  def encode(frame) do
    %{
      "op" => frame[:op] || frame["op"],
      "d"  => frame[:d]  || frame["d"],
      "s"  => frame[:s]  || frame["s"],
      "t"  => frame[:t]  || frame["t"],
    }
    |> Msgpax.pack!(iodata: false)
  end

  @doc "DISPATCH イベントフレーム (seq なし, Transport 側で付与)"
  @spec event(String.t(), map()) :: t()
  def event(event_type, data) do
    %{op: 0, d: data, s: nil, t: event_type}
  end

  @doc "エラー DISPATCH フレーム"
  @spec error_event(non_neg_integer(), String.t()) :: binary()
  def error_event(code, message) do
    encode(%{op: 0, d: %{"code" => code, "message" => message}, s: nil, t: "ERROR"})
  end
end

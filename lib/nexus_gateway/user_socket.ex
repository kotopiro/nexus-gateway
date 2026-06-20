defmodule NexusGateway.UserSocket do
  @moduledoc """
  NWP v1 の Phoenix.Socket ラッパー。
  Raw Transport (NexusGateway.Transport) を websocket: に渡すための薄いラッパー。
  Phoenix.Channel は使わない。
  """

  use Phoenix.Socket

  # チャンネルは使わない — Transport が NWP フレームを直接処理する
  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end

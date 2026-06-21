defmodule NexusGateway.Endpoint do
  use Phoenix.Endpoint, otp_app: :nexus_gateway

  # NWP v1 WebSocket エンドポイント
  #
  # Phoenix 1.8 では socket/3 の第2引数に渡したモジュールが、そのまま
  # WebSocket ハンドラ (Phoenix.Socket.Transport behaviour) として直接呼ばれる。
  # (Phoenix.Transports.WebSocket が handler.connect/1 → WebSockAdapter.upgrade/4 を実行する)
  #
  # 旧 Phoenix の websocket: [transport_module: ...] オプションは 1.8 で廃止されたため、
  # Raw Transport である NexusGateway.Transport を第2引数に直接指定する。
  # Phoenix.Channel は使わないため UserSocket ラッパーは不要。
  # websocket の :path はデフォルトで "/websocket" のため、それを指定しないと
  # 実際のマウント先が "/gateway/v1/websocket" になってしまう。
  # NWP v1 のクライアントは "/gateway/v1" に直接接続するため path: "/" を指定する。
  socket "/gateway/v1", NexusGateway.Transport,
    websocket: [
      path: "/",
      connect_info: [:peer_data, :x_headers, :uri],
      timeout: 60_000
    ],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Logger
  plug NexusGateway.Router
end

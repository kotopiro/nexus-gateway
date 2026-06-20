defmodule NexusGateway.Endpoint do
  use Phoenix.Endpoint, otp_app: :nexus_gateway

  # NWP v1 WebSocket エンドポイント
  # Phoenix.Socket.Transport の Raw Transport は
  # socket/3 ではなく websocket: [transport_module: ...] 経由で mount する
  socket "/gateway/v1", NexusGateway.UserSocket,
    websocket: [
      transport_module: NexusGateway.Transport,
      connect_info:     [:peer_data, :x_headers, :uri],
      timeout:          60_000,
    ]

  plug Plug.RequestId
  plug Plug.Logger
  plug NexusGateway.Router
end

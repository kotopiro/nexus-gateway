defmodule NexusGateway.HealthController do
  use Phoenix.Controller

  def index(conn, _params) do
    json(conn, %{
      status:  "ok",
      service: "nexus-gateway",
      version: "0.1.0",
    })
  end
end

defmodule NexusGateway.HealthController do
  use Phoenix.Controller, formats: [:json]

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "nexus-gateway",
      version: Application.spec(:nexus_gateway, :vsn) |> to_string()
    })
  end
end

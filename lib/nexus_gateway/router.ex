defmodule NexusGateway.Router do
  use Phoenix.Router, helpers: false

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NexusGateway do
    pipe_through :api
    get "/health", HealthController, :index
  end
end

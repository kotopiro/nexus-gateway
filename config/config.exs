import Config

config :nexus_gateway, NexusGateway.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: NexusGateway.ErrorJSON]],
  pubsub_server: NexusGateway.PubSub

config :nexus_gateway,
  jwt_secret:   System.get_env("JWT_SECRET", "dev_secret_CHANGE_IN_PROD"),
  gateway_url:  System.get_env("GATEWAY_URL", "ws://localhost:4000/gateway/v1")

import_config "#{config_env()}.exs"

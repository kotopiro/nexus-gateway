defmodule NexusGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :nexus_gateway,
      version: "0.1.3",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {NexusGateway.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:msgpax, "~> 2.4"},
      {:joken, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.19"},
      {:gnat, "~> 1.8"}
    ]
  end
end

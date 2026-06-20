defmodule NexusGateway.ErrorJSON do
  def render("404.json", _), do: %{error: "not found"}
  def render("500.json", _), do: %{error: "internal server error"}
end

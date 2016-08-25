defmodule JSONHyperschema.ClientBuilder.Mixfile do
  use Mix.Project

  def project do
    [
      app: :json_hyperschema_client_builder,
      version: "0.1.0",
      elixir: "~> 1.3",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps: deps()
    ]
  end

  def application do
    [applications: []]
  end

  defp deps do
    [
      {:ex_json_schema, "~> 0.5.1"},
      {:httpotion, "~> 3.0.0"},
      {:json, "~> 0.3.3"}
    ]
  end
end

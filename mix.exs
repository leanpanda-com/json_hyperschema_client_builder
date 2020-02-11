defmodule JSONHyperschema.ClientBuilder.Mixfile do
  use Mix.Project

  @version "0.11.0"

  def project do
    [
      app: :json_hyperschema_client_builder,
      version: @version,
      description: "Generate HTTP clients based on JSON Hyperschemas",
      elixir: "~> 1.5",
      package: package(),
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps: deps(),
      contributors: ["Joe Yates"],
    ]
  end

  def application do
    [applications: []]
  end

  defp package do
    %{
      licenses: ["MIT"],
      links: %{
        "GitHub" =>
        "https://github.com/leanpanda-com/json_hyperschema_client_builder"
      },
      maintainers: ["Joe Yates"]
    }
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:ex_json_schema, "~> 0.7.3"},
      {:httpoison, "~> 1.6 and >= 1.6.2"},
      {:jason, "~> 1.1"}
    ]
  end
end

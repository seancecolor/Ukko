defmodule Ukko.MixProject do
  use Mix.Project

  def project do
    [
      app: :ukko,
      version: "0.1.7",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Ukko.Application, []},
      extra_applications: [:logger, :runtime_tools, :xmerl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5.0"},
      {:sweet_xml, "~> 0.7.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end


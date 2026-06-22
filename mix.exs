defmodule Smaxr.MixProject do
  use Mix.Project

  def project do
    [
      app: :smaxr,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :konsolidator],
      mod: {Smaxr.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:konsolidator, git: "https://github.com/AsmanovLev/konsolidator.git", branch: "win7-support"},
      {:req, "~> 0.5"},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end
end

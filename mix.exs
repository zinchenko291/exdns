defmodule Exdns.MixProject do
  use Mix.Project

  def project do
    [
      app: :exdns,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Exdns, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:plug, "~> 1.15"},
      {:bandit, "~> 1.5"},
      {:libcluster, "~> 3.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      prep_release: ["deps.get", "release"]
    ]
  end

  defp releases do
    [
      exdns: [
        include_executables_for: [:unix]
      ]
    ]
  end
end

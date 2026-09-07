defmodule Claudex.MixProject do
  use Mix.Project

  def cli do
    [preferred_envs: ["test.live": :test, "test.record": :test]]
  end

  def project do
    [
      app: :claudex,
      version: "0.2.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:telemetry, "~> 1.4"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.20", only: :test},
      {:ecto, "~> 3.14", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # "test.live" runs the smoke tests in test/claudex/live/ against the real
  # Claude API. They're tagged :live and excluded by default (see
  # test/test_helper.exs) since they cost money and need network access.
  defp aliases do
    [
      "test.live": ["test --include live"],
      "test.record": &record_fixtures/1
    ]
  end

  # `mix test` rejects unknown switches, so recording is turned on through the
  # environment rather than a --record flag.
  defp record_fixtures(args) do
    System.put_env("CLAUDEX_RECORD_FIXTURES", "1")
    Mix.Task.run("test", ["--include", "live"] ++ args)
  end
end

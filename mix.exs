defmodule Claudex.MixProject do
  use Mix.Project

  @version "0.7.0"
  @source_url "https://github.com/DennisKh/claudex"
  @description "An Elixir SDK for the Claude API: messages, streaming, tools, files and batches."

  def cli do
    [preferred_envs: ["test.live": :test, "test.record": :test]]
  end

  def project do
    [
      app: :claudex,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      package: package(),
      description: @description,
      name: "Claudex",
      source_url: @source_url,
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
  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo.svg",
      favicon: "assets/logo.svg",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_url: @source_url,
      source_ref: "v" <> @version,
      groups_for_modules: [
        Messages: [
          Claudex.Messages,
          Claudex.Message,
          Claudex.ContentBlock,
          ~r/^Claudex\.ContentBlock\./,
          Claudex.Usage
        ],
        Streaming: [
          Claudex.Stream,
          Claudex.Stream.Accumulator,
          Claudex.Stream.Event,
          ~r/^Claudex\.Stream\.Event\./,
          Claudex.Stream.Forwarder,
          Claudex.Stream.Handle,
          Claudex.Stream.SSE,
          Claudex.Stream.SSE.Event
        ],
        Tools: [
          Claudex.Tool,
          Claudex.ToolRunner,
          Claudex.ToolRunner.Turn,
          ~r/^Claudex\.Tool\./
        ],
        "Other endpoints": [
          Claudex.Models,
          Claudex.Model,
          Claudex.Files,
          Claudex.FileMetadata,
          Claudex.Messages.Batches,
          Claudex.Messages.Batch,
          Claudex.Messages.Batch.RequestCounts,
          Claudex.Messages.BatchResult,
          Claudex.JSONL
        ],
        Core: [
          Claudex.Client,
          Claudex.Error,
          Claudex.Page,
          Claudex.Telemetry
        ]
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:telemetry, "~> 1.4"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.20", only: :test},
      {:ecto, "~> 3.14", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false}
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

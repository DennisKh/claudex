defmodule Claudex.MixProject do
  use Mix.Project

  @version "0.9.0"
  @source_url "https://github.com/DennisKh/claudex"
  @description "An Elixir SDK for the Claude API that runs the whole tool conversation, streams with backpressure, and derives JSON schemas from your typespecs. Messages, tools, structured outputs, files and batches."

  def cli do
    [preferred_envs: ["test.live": :test, "test.record": :test]]
  end

  def project do
    [
      app: :claudex,
      version: @version,
      # The stdlib JSON module: 1.17 has no JSON, and 1.19 is what CI runs.
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
        Core: [
          Claudex.Client,
          Claudex.Error,
          Claudex.Page,
          Claudex.Telemetry,
          Claudex.Tracing
        ],
        Messages: [
          Claudex.Messages,
          Claudex.Message,
          Claudex.OutputFormat,
          Claudex.Usage
        ],
        "Content blocks": [
          Claudex.ContentBlock,
          ~r/^Claudex\.ContentBlock\./
        ],
        Streaming: [
          Claudex.Stream,
          Claudex.Stream.Accumulator,
          Claudex.Stream.Handle
        ],
        "Stream events": [
          Claudex.Stream.Event,
          ~r/^Claudex\.Stream\.Event\./
        ],
        Tools: [
          Claudex.Tool,
          Claudex.ToolRunner,
          Claudex.ToolRunner.Turn,
          Claudex.Tool.Error,
          Claudex.Tool.CallError,
          Claudex.Tool.SchemaError
        ],
        Files: [
          Claudex.Files,
          Claudex.FileMetadata
        ],
        "Message batches": [
          Claudex.Messages.Batches,
          Claudex.Messages.Batch,
          Claudex.Messages.Batch.RequestCounts,
          Claudex.Messages.BatchResult
        ],
        Models: [
          Claudex.Models,
          Claudex.Model
        ],
        Internals: [
          Claudex.Tool.Schema,
          Claudex.Tool.Schema.StructExpansion,
          Claudex.Tool.Dispatch,
          Claudex.Stream.SSE,
          Claudex.Stream.SSE.Event,
          Claudex.Stream.Forwarder,
          Claudex.JSONL
        ]
      ]
    ]
  end

  defp deps do
    [
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7", only: [:dev, :test]},
      {:opentelemetry_exporter, "~> 1.10", only: :dev, runtime: false},
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
  # A consumer gets `opentelemetry_api` and nothing else, so tracing has to be
  # inert with no SDK present. No test can check that from :test, where the
  # SDK is a dependency, so this runs in an environment that has neither it
  # nor any other dev or test dependency.
  defp check_without_otel(_args) do
    {output, status} =
      System.cmd("mix", ["run", "priv/check_without_otel.exs"],
        env: [{"MIX_ENV", "consumer"}],
        stderr_to_stdout: true
      )

    IO.puts(output)

    if status != 0, do: Mix.raise("tracing is not inert without the OpenTelemetry SDK")
  end

  defp aliases do
    [
      "test.live": ["test --include live"],
      "test.record": &record_fixtures/1,
      "test.no_otel": &check_without_otel/1
    ]
  end

  # `mix test` rejects unknown switches, so recording is turned on through the
  # environment rather than a --record flag.
  defp record_fixtures(args) do
    System.put_env("CLAUDEX_RECORD_FIXTURES", "1")
    Mix.Task.run("test", ["--include", "live"] ++ args)
  end
end

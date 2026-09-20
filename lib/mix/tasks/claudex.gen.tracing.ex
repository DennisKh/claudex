defmodule Mix.Tasks.Claudex.Gen.Tracing do
  @shortdoc "Generates the config that sends Claudex's spans somewhere"

  @moduledoc """
  Writes the exporter config that turns Claudex's OpenTelemetry spans into
  traces in a backend.

      mix claudex.gen.tracing
      mix claudex.gen.tracing langfuse

  Claudex emits spans through `opentelemetry_api` whatever you do, and they go
  nowhere until an app adds the SDK and an exporter. This task writes the
  second half into `config/runtime.exs`, creating it if it isn't there, and
  prints the two dependencies to add.

  `config/runtime.exs` runs in every environment, so the block it writes is
  guarded with `if config_env() == :prod do`. Widen or drop that guard by
  hand if you want traces from `:dev` too.

  The backend is `otlp` unless you name one. That reads the standard
  `OTEL_EXPORTER_OTLP_*` variables and needs no Claudex-specific setup, which
  is the shape every OTLP backend accepts. `langfuse` writes the endpoint and
  the Basic auth header Langfuse wants, built from the keys it gives you.

  Naming a backend here is a convenience in a generator, not a dependency:
  nothing in `Claudex.Tracing` knows which one you picked. See
  `Claudex.Tracing` for what the spans carry and how to capture prompts.
  """

  use Mix.Task

  @backends ~w(otlp langfuse)
  @config_path "config/runtime.exs"
  @marker "config :opentelemetry_exporter"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    backend = parse!(args)

    config_path()
    |> read()
    |> append(backend)

    Mix.shell().info(instructions())
  end

  defp parse!([]), do: "otlp"
  defp parse!([backend]) when backend in @backends, do: backend

  defp parse!(_args) do
    Mix.raise("expected one of #{Enum.join(@backends, ", ")}, or nothing for otlp")
  end

  defp config_path, do: Path.join(File.cwd!(), @config_path)

  defp read(path) do
    case File.read(path) do
      {:ok, source} ->
        {path, source}

      {:error, :enoent} ->
        {path, nil}

      {:error, reason} ->
        Mix.raise("could not read #{@config_path}: #{:file.format_error(reason)}")
    end
  end

  defp append({path, nil}, backend) do
    Mix.Generator.create_file(path, "import Config\n" <> config(backend))
  end

  defp append({path, source}, backend) do
    if String.contains?(source, @marker) do
      Mix.raise("#{@config_path} already configures an exporter, leaving it alone")
    end

    File.write!(path, String.trim_trailing(source) <> "\n" <> config(backend))
    Mix.shell().info([:green, "* injecting ", :reset, @config_path])
  end

  # Without this the SDK names every trace `unknown_service:erl`, and a backend
  # holding several services cannot tell them apart.
  defp service_name do
    """

    # Names this app in every trace it sends. Unset, the SDK calls it
    # `unknown_service:erl`.
    config :opentelemetry, resource: %{service: %{name: "#{Mix.Project.config()[:app]}"}}
    """
  end

  defp config("langfuse") do
    """

    # Claudex's spans, sent to Langfuse over OTLP. Langfuse reads the GenAI
    # semantic conventions, so nothing in Claudex knows this is where they go.
    #
    # config/runtime.exs runs in every environment, so this stays behind the
    # :prod guard. Add config_env() == :dev here too, or drop the guard
    # entirely, to send traces from other environments as well.
    if config_env() == :prod do
      langfuse_auth =
        Base.encode64(
          System.fetch_env!("LANGFUSE_PUBLIC_KEY") <>
            ":" <> System.fetch_env!("LANGFUSE_SECRET_KEY")
        )

      config :opentelemetry_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint:
          System.get_env("LANGFUSE_HOST", "https://cloud.langfuse.com") <> "/api/public/otel",
        otlp_headers: [
          {"authorization", "Basic " <> langfuse_auth},
          {"x-langfuse-ingestion-version", "4"}
        ]

      # Claudex records nothing until this is on.
      config :claudex, tracing: true

      # Prompts and completions stay off a span unless you turn this on too. A
      # span goes wherever the exporter sends it, so decide that deliberately.
      config :claudex, trace_content: false
    end
    """ <> service_name()
  end

  defp config("otlp") do
    """

    # Claudex's spans, sent wherever OTEL_EXPORTER_OTLP_ENDPOINT points. The
    # exporter reads the standard OTEL_EXPORTER_OTLP_* variables itself, so
    # this only has to name the protocol.
    #
    # config/runtime.exs runs in every environment, so this stays behind the
    # :prod guard. Add config_env() == :dev here too, or drop the guard
    # entirely, to send traces from other environments as well.
    if config_env() == :prod do
      config :opentelemetry_exporter, otlp_protocol: :http_protobuf

      # Claudex records nothing until this is on.
      config :claudex, tracing: true

      # Prompts and completions stay off a span unless you turn this on too. A
      # span goes wherever the exporter sends it, so decide that deliberately.
      config :claudex, trace_content: false
    end
    """ <> service_name()
  end

  defp instructions do
    """

    Add the SDK and the exporter to mix.exs, which Claudex deliberately does
    not depend on:

        {:opentelemetry, "~> 1.7"},
        {:opentelemetry_exporter, "~> 1.10"}

    The block is guarded with `if config_env() == :prod do`, because
    config/runtime.exs runs in every environment. Widen it by hand to trace a
    development run.

    Then run. See Claudex.Tracing for what each span carries, and turn on
    `config :claudex, trace_content: true` when you want prompts, completions
    and tool arguments on the spans as well.
    """
  end
end

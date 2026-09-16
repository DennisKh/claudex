defmodule Claudex.Tracing do
  @moduledoc """
  OpenTelemetry spans for the requests Claudex makes, the streams it reads,
  and the tool conversations it runs.

  This feature is disabled by default. Enable it by setting:

      config :claudex, tracing: true

  Nothing is measured, built or recorded while that is false, whatever else
  is running. Claudex depends on `opentelemetry_api` alone, which starts no
  processes, so an app that never traces carries one library that does
  nothing. One that does adds the SDK and an exporter itself:

      # mix.exs
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"}

  `mix claudex.gen.tracing` writes the exporter config for you — see
  `Mix.Tasks.Claudex.Gen.Tracing`.

  Name the service too, or every trace arrives as `unknown_service:erl` and a
  backend holding more than one app cannot tell them apart. It is a resource
  attribute, set once for the VM rather than per span:

      config :opentelemetry, resource: %{service: %{name: "my_app"}}

  The SDK looks for that name in `OTEL_SERVICE_NAME`, then in the resource
  config above, then in the release name, and calls it after the running
  program when it finds none. `unknown_service:erl` means it fell all the way
  through.

  ## SDK defaults that shape a Claudex trace

  Nothing here needs setting. Two of `opentelemetry`'s own defaults decide
  what a trace looks like once it grows, and both are plain app config:

      config :opentelemetry,
        attribute_value_length_limit: 8_192,
        sampler: {:parent_based, %{root: {:trace_id_ratio_based, 0.1}}}

  `attribute_value_length_limit` is `:infinity`, so a conversation recorded
  with `trace_content: true` is exported whole. Cap it when a collector
  rejects large spans; the messages are the attribute that gets cut.
  `OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT` sets the same value.

  `sampler` is `{:parent_based, %{root: :always_on}}`, so every run is traced.
  A run is one trace, so the ratio above keeps one conversation in ten whole
  rather than a tenth of every conversation. `OTEL_TRACES_SAMPLER` and
  `OTEL_TRACES_SAMPLER_ARG` set the same pair, as
  `parentbased_traceidratio` and `0.1`.

  Attributes follow the
  [GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/),
  so any backend that reads them shows the model, the token counts and the
  stop reason without a Claudex-specific integration.

  ## What a trace looks like

  A whole tool conversation is one trace, whatever number of turns it took:

      invoke_agent claude-opus-5          the run, from question to answer
      ├── turn                            claudex.turn.index = 1
      │   ├── chat claude-opus-5          the request
      │   └── execute_tool read_file      each tool it asked for
      └── turn                            claudex.turn.index = 2
          └── chat claude-opus-5

  `invoke_agent`, `chat` and `execute_tool` are the conventions' own operation
  names, so a backend classifies each one. `turn` is Claudex's: the
  conventions have no operation for a step inside an invocation, and a turn's
  request and tool calls belong together.

  A single `Claudex.Messages.create/2` or `stream!/2` is one `chat` span with
  no conversation around it.

  ## Naming a conversation

  A trace is one run. What groups several of them is a session, and you name
  it, because only your app knows what a conversation belongs to:

      Claudex.ToolRunner.run(client, params, session: chat.id)

  This attaches session.id to the conversation span. Because it uses a standard
  attribute format, grouping works consistently across tracing backends whether
  the identifier is a chat ID, custom session name, or request ID. Without this
  attribute, the trace remains unlinked, which is appropriate for standalone runs.

  ## Your own spans

  Claudex starts its spans under whatever is current, so a span of your own
  adopts the whole conversation into your trace:

      Tracer.with_span "my_app.handle_message", %{attributes: %{"user.id" => id}} do
        Claudex.Messages.create(client, params)
      end

  That is the way in for anything Claudex has no option for, a user id above
  all, and the only way for a single `Claudex.Messages.create/2`, which is one
  `chat` span with no conversation around it to name.

  ## Sending traces to Langfuse

  Langfuse accepts OTLP, so nothing here knows it exists. Its keys become one
  exporter config in your own `runtime.exs`:

      auth =
        Base.encode64(
          System.fetch_env!("LANGFUSE_PUBLIC_KEY") <> ":" <> System.fetch_env!("LANGFUSE_SECRET_KEY")
        )

      config :opentelemetry_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint: System.get_env("LANGFUSE_HOST", "https://cloud.langfuse.com") <> "/api/public/otel",
        otlp_headers: [
          {"authorization", "Basic " <> auth},
          {"x-langfuse-ingestion-version", "4"}
        ]

  Point the endpoint and header somewhere else and the same spans reach
  Honeycomb, Datadog, Phoenix/Arize or Braintrust.

  `docker-compose.langfuse.yml` in this repository runs the whole stack
  locally if you want to see the traces without sending them anywhere. The
  README has the two commands.

  ## Capturing prompts and completions

  Message content is off by default, because a span reaches wherever your
  exporter sends it:

      config :claudex, trace_content: true

  With it on, the conversation span carries the question the run started with
  and the answer it ended on, a request span carries the messages and the
  reply, and a tool span carries the arguments it was called with and what it
  returned. A trace's own input and output are the run's, which is what a
  backend shows on a session or in a list of traces.
  Everything else is recorded either way: model, token counts, latency, stop
  reason and tool names, which is why a trace is useful without content.

  This is what fills the input and output panels of a tracing UI. Seeing them
  empty means content capture is off, not that something is missing.

  ## Alongside your own tracing

  Claudex's spans are its own. They carry the instrumentation scope
  `claudex`, so a backend can tell them from yours and a filter can drop
  them, and nothing here configures a tracer, a sampler, an exporter or a
  processor: those stay entirely yours. Claudex only ever starts spans,
  restoring whatever was current when each one closes.

  Each span's attributes go on that span, held rather than looked up when it
  ends. A caller pulling a stream one event at a time can run its own traced
  work in between, and an app that starts a span in one callback and ends it
  in another is not made to pay for it.

  ## Turning it off

  `config :claudex, tracing: false`, which is the default, is the whole
  switch: `enabled?/0` is false, no attributes are built, no messages are
  shaped, no spans are started and the stream records nothing. A tool
  conversation runs exactly as it would if this module did not exist.

  A span never fails the work it measures either. Every call into the tracer
  is guarded, so an exporter that raises or a tracer that is misconfigured
  costs the trace and nothing else.
  """

  @tracer_scope __MODULE__

  @doc """
  Checks the two things a span needs: `config :claudex, tracing: true`, and an
  OpenTelemetry SDK loaded to record into.

  Nothing is built or measured while this is false.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    if Application.get_env(:claudex, :tracing, false), do: tracer_records?(), else: false
  end

  @doc """
  Runs `fun` inside a span, handing it the span to record onto.

  `describe` returns `{name, attributes}` and is only called when `enabled?/0`
  is true, so building the attributes costs nothing while tracing is off.
  `fun` is given the span, or `:untraced` when there is none, and whatever it
  returns is returned here. An exception is recorded on the span and re-raised
  unchanged.
  """
  @spec span((-> {String.t(), map()}), (term() -> result)) :: result when result: term()
  def span(describe, fun) when is_function(describe, 0) and is_function(fun, 1) do
    if enabled?(), do: traced(describe, fun), else: fun.(:untraced)
  end

  @doc """
  Starts a span, makes it current, and returns the handle `end_span/1` takes.

  `describe` returns `{name, attributes}` and is only called while tracing is
  on; the handle is `:untraced` otherwise.
  """
  @spec start_span((-> {String.t(), map()})) :: term()
  def start_span(describe) when is_function(describe, 0) do
    if enabled?() do
      {name, attributes} = describe.()
      start(name, attributes)
    else
      :untraced
    end
  end

  @doc """
  Ends a span from `start_span/1` and makes its parent current again.

  Ending a span is what hands it to the exporter. An `:untraced` handle does
  nothing.
  """
  @spec end_span(term()) :: :ok
  def end_span(span_ctx), do: stop(span_ctx)

  @doc """
  Checks whether the span current in this process is recording.

  `enabled?/0` answers whether Claudex traces at all; this answers for the
  span in hand, which a sampler may have dropped.
  """
  @spec recording?() :: boolean()
  def recording? do
    :otel_span.is_recording(:otel_tracer.current_span_ctx())
  rescue
    _any -> false
  catch
    _kind, _reason -> false
  end

  @doc """
  The tracing context of the calling process, to attach in another one.

  A span is found through the process dictionary, so work handed to a new
  process starts a trace of its own unless the context goes with it.
  """
  @spec context() :: term()
  def context do
    :otel_ctx.get_current()
  rescue
    _any -> :undefined
  catch
    _kind, _reason -> :undefined
  end

  @doc "Adopts a context from `context/0` into this process."
  @spec attach(term()) :: :ok
  def attach(:undefined), do: :ok

  def attach(context) do
    :otel_ctx.attach(context)

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Returns a handle for the span current in this process, in the shape
  `set_attributes/2` and `set_error/2` take.

  The handle carries no parent, so ending it would leave this process with no
  current span.
  """
  @spec current_span() :: term()
  def current_span do
    {:otel_tracer.current_span_ctx(), :undefined}
  rescue
    _any -> :untraced
  catch
    _kind, _reason -> :untraced
  end

  @doc "Puts `attributes` on `span`. An `:untraced` handle does nothing."
  @spec set_attributes(term(), map()) :: :ok
  def set_attributes(:untraced, _attributes), do: :ok

  def set_attributes({span_ctx, _parent}, attributes) do
    :otel_span.set_attributes(span_ctx, attributes)

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Marks `span` as failed, with `message` as its status.

  An `:untraced` handle does nothing.
  """
  @spec set_error(term(), String.t()) :: :ok
  def set_error(:untraced, _message), do: :ok
  def set_error({span_ctx, _parent}, message), do: put_error(span_ctx, message)

  @doc """
  Checks whether prompts and completions go onto spans.

  Off unless `config :claudex, trace_content: true`.
  """
  @spec trace_content?() :: boolean()
  def trace_content?, do: Application.get_env(:claudex, :trace_content, false)

  defp traced(describe, fun) do
    {name, attributes} = describe.()
    span_ctx = start(name, attributes)

    try do
      fun.(span_ctx)
    rescue
      exception ->
        record_exception(span_ctx, exception, __STACKTRACE__)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        fail(span_ctx, "#{kind}: #{inspect(reason)}")
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      stop(span_ctx)
    end
  end

  defp tracer_records? do
    case :opentelemetry.get_application_tracer(@tracer_scope) do
      {:otel_tracer_noop, _config} -> false
      _tracer -> true
    end
  rescue
    _any -> false
  catch
    _kind, _reason -> false
  end

  defp start(name, attributes) do
    parent = :otel_tracer.current_span_ctx()
    tracer = :opentelemetry.get_application_tracer(@tracer_scope)
    span_ctx = :otel_tracer.start_span(tracer, name, %{attributes: attributes})
    :otel_tracer.set_current_span(span_ctx)

    {span_ctx, parent}
  rescue
    _any -> :untraced
  catch
    _kind, _reason -> :untraced
  end

  defp stop(:untraced), do: :ok

  defp stop({span_ctx, parent}) do
    :otel_span.end_span(span_ctx)
    :otel_tracer.set_current_span(parent)

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp record_exception(:untraced, _exception, _stacktrace), do: :ok

  defp record_exception({span_ctx, _parent}, exception, stacktrace) do
    :otel_span.add_event(span_ctx, :exception, %{
      "exception.type" => inspect(exception.__struct__),
      "exception.message" => Exception.message(exception),
      "exception.stacktrace" => Exception.format_stacktrace(stacktrace)
    })

    :otel_span.set_status(span_ctx, :opentelemetry.status(:error, Exception.message(exception)))

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp fail(:untraced, _message), do: :ok

  defp fail({span_ctx, _parent}, message), do: put_error(span_ctx, message)

  defp put_error(span_ctx, message) do
    :otel_span.set_status(span_ctx, :opentelemetry.status(:error, message))

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end
end

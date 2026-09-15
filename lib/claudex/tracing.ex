defmodule Claudex.Tracing do
  @moduledoc """
  OpenTelemetry spans for the requests Claudex makes, the streams it reads,
  and the tool conversations it runs.

  Claudex depends on `opentelemetry_api` alone, which starts no processes and
  resolves to a no-op tracer when nothing else is present. An app that never
  traces pays nothing and needs no configuration. One that does adds the SDK
  and an exporter itself:

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

  ## SDK settings that interact with what Claudex records

  These belong to `opentelemetry` rather than to Claudex, and the defaults
  suit most apps. Four change what a Claudex trace looks like:

    * `OTEL_RESOURCE_ATTRIBUTES` puts `key=value` pairs on every span and is
      read by default. `deployment.environment=staging,service.version=1.4.0`
      is the usual pair, and is how one backend tells your environments apart.
    * `attribute_value_length_limit` is `:infinity` by default, so a long
      conversation captured with `trace_content: true` goes out whole. Cap it
      with `OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT` if your collector rejects
      large spans, and expect the messages to be the attribute that gets cut.
    * `sampler` is `{:parent_based, %{root: :always_on}}` by default, so every
      conversation is traced. A run is one trace, so a ratio sampler drops or
      keeps whole conversations rather than pieces of them.
    * `processors` are batched by default, which is right for a running app
      and wrong for a script: a short-lived VM can exit before the batch is
      sent. Use `:otel_simple_processor` when a mix task or a release command
      has to see its own traces.

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

  Every turn is named `turn`, with its number in `claudex.turn.index`. A span
  name labels a kind of work rather than one instance of it, so a backend that
  draws a graph folds all the turns into one node and counts them. Numbering
  the names would draw a five-turn run as five separate nodes.

  A single `Claudex.Messages.create/2` or `stream!/2` is one `chat` span with
  no conversation around it.

  ## Naming a conversation

  A trace is one run. What groups several of them is a session, and you name
  it, because only your app knows what a conversation belongs to:

      Claudex.ToolRunner.run(client, params, session: chat.id)

  That sets `session.id` on the conversation span. It is a standard attribute
  rather than one backend's idea, so a chat id, a user-given name or a request
  id groups the same way wherever the spans are sent. Without it a run's trace
  stands alone, which is right when it belongs to nothing larger.

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

  ## Tracing is optional

  Adding nothing is a supported configuration. Without the SDK the tracer is
  a no-op, `recording?/0` is false, and every span call returns without
  reaching anything: a tool conversation runs exactly as it would if this
  module did not exist. There is no dependency to add, no config to write and
  no error to handle.

  A span never fails the work it measures either. Every call into the tracer
  is guarded, so an exporter that raises or a tracer that is misconfigured
  costs the trace and nothing else.
  """

  @tracer_scope __MODULE__

  @doc false
  @spec span(String.t(), map(), (-> result)) :: result when result: term()
  def span(name, attributes, fun) when is_function(fun, 0) do
    span_ctx = start(name, attributes)

    try do
      fun.()
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

  @doc false
  @spec start_span(String.t(), map()) :: term()
  def start_span(name, attributes), do: start(name, attributes)

  @doc false
  @spec end_span(term()) :: :ok
  def end_span(span_ctx), do: stop(span_ctx)

  @doc false
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

  @doc false
  @spec current_span() :: term()
  def current_span do
    {:otel_tracer.current_span_ctx(), :undefined}
  rescue
    _any -> :untraced
  catch
    _kind, _reason -> :untraced
  end

  @doc false
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

  @doc false
  @spec set_attributes(map()) :: :ok
  def set_attributes(attributes) when is_map(attributes) do
    :otel_span.set_attributes(:otel_tracer.current_span_ctx(), attributes)

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  @spec set_error(term(), String.t()) :: :ok
  def set_error(:untraced, _message), do: :ok
  def set_error({span_ctx, _parent}, message), do: put_error(span_ctx, message)

  @doc false
  @spec set_error(String.t()) :: :ok
  def set_error(message) do
    put_error(:otel_tracer.current_span_ctx(), message)
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Whether prompts and completions are recorded on spans.

  Off unless `config :claudex, trace_content: true`.
  """
  @spec trace_content?() :: boolean()
  def trace_content? do
    case Application.get_env(:claudex, :trace_content, false) do
      true -> true
      _off -> false
    end
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

  # Built by hand rather than through record_exception/5, which formats an
  # Elixir exception struct as an Erlang term and puts the whole thing in
  # exception.type. The semantic convention wants the module and the message.
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

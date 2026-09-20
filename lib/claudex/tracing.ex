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

      Claudex.Messages.create(client, params, session: chat.id)
      Claudex.Messages.stream!(client, params, session: chat.id)
      Claudex.Messages.stream_to(client, params, to: self(), session: chat.id)
      Claudex.Messages.count_tokens(client, params, session: chat.id)
      Claudex.Tool.call(MyApp.Tools, name, input, session: chat.id)
      Claudex.Files.upload(client, path, session: chat.id)
      Claudex.ToolRunner.run(client, params, session: chat.id)

  That puts `session.id` on the request's span, and on a run's conversation,
  request and tool spans. The turn spans a run groups its work under carry
  none, since a turn is a step inside a conversation that already names one.
  The id is yours: a chat row's id, a support ticket, whatever the conversation
  belongs to. Without one the trace stands alone, which is right for a run that
  belongs to nothing larger.

  `set_session/1` names one for every span the calling process builds after it,
  for code that would otherwise thread the id through each call:

      Claudex.Tracing.set_session(chat.id)

      Claudex.Messages.create(client, params)
      Claudex.Tool.call(MyApp.Tools, name, input)

  A `:session` passed to a call wins over that. `set_session(nil)` clears it,
  which a process serving more than one conversation has to do, since the id
  otherwise carries into the next request it makes. It rides OpenTelemetry
  baggage, so it reaches the process Claudex spawns to stream a reply, and an
  app that configures a baggage propagator carries it into its own outbound
  calls under the same context. Claudex sends no propagation headers to
  Anthropic, so nothing reaches Anthropic itself.

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

  alias Claudex.Message
  alias Claudex.Tracing.Attributes

  @tracer_scope __MODULE__
  @session_baggage_key "session.id"

  @typedoc """
  Names the conversation a call belongs to, as `session.id` on its span.

  Taken by the request functions in `Claudex.Messages`, by
  `Claudex.Tool.call/4` and by `Claudex.ToolRunner.run/3`. `set_session/1`
  names one for every span the calling process builds instead.
  """
  @type session_option :: {:session, String.t() | nil}

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
  Sets the session id for the current process, to name the conversation its
  spans belong to. See "Naming a conversation" above.

  Stored in OpenTelemetry baggage, which `context/0` carries and `attach/1`
  restores, so it reaches a process Claudex spawns to stream a reply. Pass
  `nil` to clear it, for a process a pool reuses across conversations. Does
  nothing while `enabled?/0` is false.

  A row id or any other value `to_string/1` accepts becomes a string, so
  `session: chat.id` works whatever the column type is. A value with no string
  form leaves the current session alone rather than raising, since a tracing id
  cannot be worth breaking the request it was meant to label.
  """
  @spec set_session(term()) :: :ok
  def set_session(nil), do: store_session(nil)

  def set_session(session_id) do
    case normalize_session(session_id) do
      nil -> :ok
      id -> store_session(id)
    end
  end

  @doc false
  @spec normalize_session(term()) :: String.t() | nil
  def normalize_session(session) when is_binary(session), do: session
  def normalize_session(nil), do: nil

  def normalize_session(session) do
    if String.Chars.impl_for(session), do: to_string(session), else: nil
  end

  @doc """
  Returns the session id set with `set_session/1` for the current process, or
  `nil` when none is set.
  """
  @spec session_id() :: String.t() | nil
  def session_id do
    case :otel_baggage.get_all() do
      %{@session_baggage_key => {value, _metadata}} -> value
      _no_session -> nil
    end
  rescue
    _any -> nil
  catch
    _kind, _reason -> nil
  end

  @doc """
  Starts the span that groups a whole conversation, and returns the handle
  `end_conversation/3` takes.

  `params` is the request the conversation runs, read for the model and, when
  `trace_content` is on, the prompt and tool definitions. `opts` takes
  `:session` for `session.id` and `:max_turns` for a loop with a limit.

      span = Claudex.Tracing.start_conversation(params, session: chat.id)

      {:ok, message} = Claudex.Messages.create(client, params, session: chat.id)

      Claudex.Tracing.end_conversation(span, message)

  `Claudex.ToolRunner` opens one of these around a run. An app driving the
  loop itself opens its own, so its requests and tool calls land in one trace
  instead of one each. The handle is an ordinary span handle, so
  `set_attributes/2` and `set_error/2` take it.

  A span stays open and unexported until `end_conversation/3` runs, and the
  process goes on nesting new spans under it, so every path out of an exchange
  has to end it. Within one function that is `try/after`; an app holding the
  span across callbacks ends it on each way the exchange can finish, including
  the error and abandoned ones.
  """
  @spec start_conversation(map()) :: term()
  @spec start_conversation(map(), keyword()) :: term()
  def start_conversation(params, opts \\ []) do
    start_span(fn ->
      Attributes.conversation(params, Keyword.get(opts, :max_turns), Keyword.get(opts, :session))
    end)
  end

  @doc """
  Records how a conversation ended and ends its span.

  `message` is the last reply the conversation produced, recorded as its output
  when `trace_content` is on. `stop` is your own word for why the loop
  finished, recorded as `claudex.stop`. The two are independent: a turn
  cancelled before any content has a stop and no message. Ending with neither
  still closes the span.
  """
  @spec end_conversation(term()) :: :ok
  @spec end_conversation(term(), Message.t() | nil) :: :ok
  @spec end_conversation(term(), Message.t() | nil, atom() | nil) :: :ok
  def end_conversation(span, message \\ nil, stop \\ nil) do
    set_attributes(span, Attributes.conversation_result(message, stop))

    end_span(span)
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

  defp store_session(session_id) do
    if enabled?(), do: put_session_baggage(session_id)

    :ok
  end

  # otel_baggage has no call to remove one key, only clear/0 for all of it, so
  # clearing ours means reading the rest back and setting it again.
  defp put_session_baggage(nil) do
    remaining = :otel_baggage.get_all() |> Map.delete(@session_baggage_key)
    :otel_baggage.clear()
    :otel_baggage.set(remaining)

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp put_session_baggage(session_id) do
    :otel_baggage.set(@session_baggage_key, session_id)

    :ok
  rescue
    _any -> :ok
  catch
    _kind, _reason -> :ok
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

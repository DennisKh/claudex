defmodule Claudex.ChunkStream do
  @moduledoc false

  alias Claudex.{API, Client, Error, Tracing}
  alias Claudex.Tracing.Attributes

  @typedoc """
  An option for `stream/4`, described under "Options" there.
  """
  @type option :: {:cancel_ref, reference()} | Tracing.session_option()

  @typedoc """
  How a body becomes items: a `Claudex.ChunkStream.Decoder` that splits the
  bytes, and a function that turns each piece it completes into the items to
  yield.
  """
  @type decode :: {module(), (term() -> [term()])}

  @doc """
  Streams a response body as the items `decode` makes of it.

  Enumerating spawns a process that owns the request and hands chunks over one
  at a time, waiting for the consumer to ask for the next. That wait is the
  backpressure: at most one chunk is read ahead of the consumer, and the socket
  stalls behind it.

  `request_options` reach `Req.request/2`. `opts` are this function's own, and
  are read when enumeration starts rather than here.

  Raises `Claudex.Error` on a non-2xx response, a transport failure, or the
  owning process dying, and whatever `decode` raises. Anything raised while
  decoding fails the request, so its telemetry and span report it.

  ## Options

    * `:cancel_ref` - the reference a `{:claudex_cancel, ref}` message carries
      to stop the stream part-way. One is made for you when it is absent, and
      nothing can cancel a stream whose reference the caller never saw.
    * `:session` - names the conversation for tracing, as
      `t:Claudex.Tracing.session_option/0` describes.
  """
  @spec stream(Client.t(), keyword(), decode()) :: Enumerable.t()
  @spec stream(Client.t(), keyword(), decode(), [option()]) :: Enumerable.t()
  def stream(%Client{} = client, request_options, decode, opts \\ []) do
    cancel_ref = Keyword.get_lazy(opts, :cancel_ref, &make_ref/0)

    Stream.resource(
      fn -> connect(client, request_options, decode, cancel_ref, opts) end,
      &next/1,
      &disconnect/1
    )
  end

  defp connect(client, request_options, decode, cancel_ref, opts) do
    consumer = self()
    producer_ref = make_ref()

    # Test stubs and sandboxes resolve ownership through $callers, and the
    # request runs in a process the caller never sees, so pass the chain on.
    callers = [consumer | Process.get(:"$callers", [])]

    {producer, producer_monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        run(client, request_options, consumer, producer_ref)
      end)

    metadata =
      %{
        method: Keyword.get(request_options, :method, :get),
        path: Keyword.get(request_options, :url)
      }
      |> API.put_model(request_options)

    :telemetry.execute(
      [:claudex, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    %{
      producer: producer,
      producer_monitor: producer_monitor,
      producer_ref: producer_ref,
      producer_down?: false,
      done?: false,
      failure: nil,
      cause: nil,
      stacktrace: nil,
      decoder: decoder(decode),
      metadata: metadata,
      cancel_ref: cancel_ref,
      span: start_span(metadata, request_options, opts),
      first_chunk: nil,
      chunks: 0,
      bytes: 0,
      response: %{status: nil, request_id: nil},
      started: System.monotonic_time()
    }
  end

  defp next(%{done?: true} = state), do: {:halt, state}
  defp next(%{failure: failure} = state) when not is_nil(failure), do: {:halt, state}

  defp next(
         %{producer_ref: producer_ref, producer_monitor: producer_monitor, cancel_ref: cancel_ref} =
           state
       ) do
    receive do
      # Halting will run disconnect/1, which kills the producer and closes the socket.
      {:claudex_cancel, ^cancel_ref} = cancel ->
        # The caller reads the same message to tell a cancelled stream from a
        # finished one, and this receive runs in the caller's own process.
        send(self(), cancel)
        {:halt, state}

      {^producer_ref, :response, response} ->
        {[], %{state | response: response}}

      {^producer_ref, :chunk, data} ->
        send(state.producer, {producer_ref, :demand})

        state
        |> count(data)
        |> decode({:chunk, data})

      {^producer_ref, {:done, response}} ->
        decode(%{state | done?: true, response: response}, :done)

      {^producer_ref, {:error, %Error{} = error}} ->
        {:halt,
         %{
           state
           | failure: error,
             response: %{status: error.status, request_id: error.request_id}
         }}

      {^producer_ref, {:transport_error, exception}} ->
        {:halt, %{state | failure: Error.from_transport(exception), cause: exception}}

      {:DOWN, ^producer_monitor, :process, _producer, reason} ->
        error = Error.stream_error("the process running the request exited: #{inspect(reason)}")

        {:halt, %{state | failure: error, producer_down?: true}}
    end
  end

  defp disconnect(state) do
    close(state)
    report(state)
    record_span(state)

    fail(state)
  end

  defp fail(%{failure: nil}), do: :ok
  defp fail(%{failure: error, stacktrace: nil}), do: raise(error)
  defp fail(%{failure: error, stacktrace: stacktrace}), do: reraise(error, stacktrace)

  defp decoder({module, parse}), do: %{module: module, parse: parse, buffer: module.new()}

  defp feed(%{module: module, buffer: buffer}, {:chunk, data}), do: module.decode(buffer, data)
  defp feed(%{module: module, buffer: buffer}, :done), do: module.flush(buffer)

  defp count(state, data) do
    %{
      state
      | chunks: state.chunks + 1,
        bytes: state.bytes + byte_size(data),
        first_chunk: state.first_chunk || System.monotonic_time()
    }
  end

  defp decode(%{decoder: decoder} = state, input) do
    {decoded, buffer} = feed(decoder, input)

    to_items(decoded, [], %{state | decoder: %{decoder | buffer: buffer}})
  rescue
    error -> {:halt, failed(state, error, __STACKTRACE__)}
  end

  defp to_items([], items, state), do: {items, state}

  defp to_items([piece | rest], items, state) do
    case piece_items(state.decoder.parse, piece) do
      {:ok, parsed} -> to_items(rest, items ++ parsed, state)
      {:error, error, stacktrace} -> {items, failed(state, error, stacktrace)}
    end
  end

  defp piece_items(parse, piece) do
    {:ok, parse.(piece)}
  rescue
    error -> {:error, error, __STACKTRACE__}
  end

  defp failed(state, %Error{} = error, _stacktrace), do: %{state | failure: error}
  defp failed(state, error, stacktrace), do: %{state | failure: error, stacktrace: stacktrace}

  defp report(%{failure: nil} = state), do: report(state, :stop, %{})

  defp report(%{failure: %Error{status: status} = error} = state) when is_integer(status),
    do: report(state, :stop, %{error_type: error.type})

  defp report(%{cause: %{} = cause} = state),
    do: report(state, :exception, API.failure_metadata(cause))

  defp report(%{failure: %Error{} = error} = state),
    do: report(state, :exception, %{kind: :error, error: Error, error_type: error.type})

  defp report(%{failure: error} = state),
    do: report(state, :exception, %{kind: :error, error: error.__struct__})

  defp report(state, event, failure) do
    :telemetry.execute(
      [:claudex, :request, event],
      telemetry_measurements(state),
      state.metadata |> Map.merge(state.response) |> Map.merge(failure)
    )
  end

  defp close(%{producer: producer, producer_ref: producer_ref} = state) do
    send(producer, {producer_ref, :cancel})
    Process.exit(producer, :kill)
    await_down(state)
    flush(producer_ref)
  end

  defp await_down(%{producer_down?: true}), do: :ok

  defp await_down(%{producer_monitor: producer_monitor}) do
    receive do
      {:DOWN, ^producer_monitor, :process, _producer, _reason} -> :ok
    end
  end

  defp flush(producer_ref) do
    receive do
      {^producer_ref, _message} -> flush(producer_ref)
      {^producer_ref, _tag, _payload} -> flush(producer_ref)
    after
      0 -> :ok
    end
  end

  defp telemetry_measurements(state) do
    %{
      duration: System.monotonic_time() - state.started,
      chunks: state.chunks,
      bytes: state.bytes
    }
  end

  defp record_span(state) do
    Tracing.set_attributes(state.span, Attributes.stream(span_measurements(state)))
    record_failure(state)
    Tracing.end_span(state.span)
  end

  defp start_span(metadata, request_options, opts) do
    Tracing.start_span(fn -> Attributes.request(metadata, request_options, opts) end)
  end

  defp record_failure(%{failure: nil}), do: :ok

  defp record_failure(%{failure: error, span: span}),
    do: Tracing.set_error(span, Exception.message(error))

  defp span_measurements(state) do
    %{
      chunks: state.chunks,
      bytes: state.bytes,
      started: state.started,
      first_chunk: state.first_chunk,
      status: state.response.status
    }
  end

  defp run(client, request_options, consumer, producer_ref) do
    consumer_monitor = Process.monitor(consumer)

    options =
      Keyword.merge(request_options,
        into: collector(consumer, producer_ref, consumer_monitor),
        retry: &retry_decision/2
      )

    send(consumer, {producer_ref, outcome(Req.request(client.req, options))})
  end

  defp collector(consumer, producer_ref, consumer_monitor) do
    fn {:data, data}, {request, response} ->
      if response.status in 200..299 do
        announce_response(request, response, consumer, producer_ref)
        send(consumer, {producer_ref, :chunk, data})

        request
        |> Req.Request.put_private(:claudex_streamed, true)
        |> await_demand(response, producer_ref, consumer_monitor)
      else
        {:cont, {request, %{response | body: response.body <> data}}}
      end
    end
  end

  # Sent once, ahead of the first chunk, so a stream that fails or is stopped
  # part-way still reports the status and request id it got.
  defp announce_response(request, response, consumer, producer_ref) do
    if not Req.Request.get_private(request, :claudex_streamed, false) do
      send(consumer, {producer_ref, :response, response_metadata(response)})
    end
  end

  defp await_demand(request, response, producer_ref, consumer_monitor) do
    receive do
      {^producer_ref, :demand} -> {:cont, {request, response}}
      {^producer_ref, :cancel} -> {:halt, {request, response}}
      {:DOWN, ^consumer_monitor, :process, _consumer, _reason} -> {:halt, {request, response}}
    end
  end

  defp retry_decision(request, response_or_exception) do
    case Client.retry_decision(request, response_or_exception) do
      false -> false
      decision -> allow_unless_streamed(request, decision)
    end
  end

  # Retrying after chunks have reached the consumer would replay part of the
  # body and bill the request twice, so a retry is only allowed while the
  # response is still untouched.
  defp allow_unless_streamed(request, decision) do
    if Req.Request.get_private(request, :claudex_streamed, false) do
      :telemetry.execute([:claudex, :retry, :declined], %{}, %{
        reason: "part of the response already reached the caller"
      })

      false
    else
      decision
    end
  end

  defp response_metadata(response),
    do: %{status: response.status, request_id: API.request_id(response)}

  defp outcome({:ok, %Req.Response{status: status} = response}) when status in 200..299,
    do: {:done, response_metadata(response)}

  defp outcome({:ok, %Req.Response{status: status, body: body} = response}) do
    {:error, Error.from_response(status, body, API.request_id(response))}
  end

  defp outcome({:error, exception}), do: {:transport_error, exception}
end

defmodule Claudex.ChunkStream do
  @moduledoc false

  alias Claudex.{API, Client, Error, Tracing}
  alias Claudex.Tracing.Attributes

  @typedoc """
  An option for `stream/3`, described under "Options" there.
  """
  @type option :: {:cancel_ref, reference()} | Tracing.session_option()

  @doc """
  Streams a response body as raw binary chunks.

  Enumerating spawns a process that owns the request and hands chunks over one
  at a time, waiting for the consumer to ask for the next. That wait is the
  backpressure: at most one chunk is read ahead of the consumer, and the socket
  stalls behind it.

  `request_options` reach `Req.request/2`. `opts` are this function's own, and
  are read when enumeration starts rather than here.

  Raises `Claudex.Error` on a non-2xx response, a transport failure, or the
  owning process dying.

  ## Options

    * `:cancel_ref` - the reference a `{:claudex_cancel, ref}` message carries
      to stop the stream part-way. One is made for you when it is absent, and
      nothing can cancel a stream whose reference the caller never saw.
    * `:session` - names the conversation for tracing, as
      `t:Claudex.Tracing.session_option/0` describes.
  """
  @spec stream(Client.t(), keyword()) :: Enumerable.t()
  @spec stream(Client.t(), keyword(), [option()]) :: Enumerable.t()
  def stream(%Client{} = client, request_options, opts \\ []) do
    cancel_ref = Keyword.get_lazy(opts, :cancel_ref, &make_ref/0)

    Stream.resource(
      fn -> connect(client, request_options, cancel_ref, opts) end,
      &next/1,
      &disconnect/1
    )
  end

  defp connect(client, request_options, cancel_ref, opts) do
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
      done?: false,
      failure: nil,
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

      {^producer_ref, :chunk, data} ->
        send(state.producer, {producer_ref, :demand})

        {[data],
         %{
           state
           | chunks: state.chunks + 1,
             bytes: state.bytes + byte_size(data),
             first_chunk: state.first_chunk || System.monotonic_time()
         }}

      {^producer_ref, {:done, response}} ->
        {:halt, %{state | done?: true, response: response}}

      {^producer_ref, {:error, error}} ->
        {:halt, %{state | failure: error}}

      {:DOWN, ^producer_monitor, :process, _producer, reason} ->
        error = Error.stream_error("the process running the request exited: #{inspect(reason)}")

        {:halt, %{state | failure: error}}
    end
  end

  defp disconnect(%{failure: nil} = state) do
    close(state)

    :telemetry.execute(
      [:claudex, :request, :stop],
      telemetry_measurements(state),
      Map.merge(state.metadata, state.response)
    )

    record_span(state)

    :ok
  end

  defp disconnect(%{failure: error} = state) do
    close(state)

    :telemetry.execute(
      [:claudex, :request, :exception],
      telemetry_measurements(state),
      Map.merge(state.metadata, %{kind: :error, error: error.__struct__})
    )

    record_span(state)

    raise error
  end

  defp close(%{
         producer: producer,
         producer_monitor: producer_monitor,
         producer_ref: producer_ref
       }) do
    send(producer, {producer_ref, :cancel})
    Process.demonitor(producer_monitor, [:flush])
    Process.exit(producer, :kill)

    :ok
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

  defp record_failure(%{response: %{status: status}} = state) when is_integer(status) do
    if status not in 200..299, do: Tracing.set_error(state.span, "HTTP #{status}")
  end

  defp record_failure(%{failure: error} = state) when not is_nil(error) do
    Tracing.set_error(state.span, Exception.message(error))
  end

  defp record_failure(%{done?: false} = state) do
    Tracing.set_error(state.span, "the stream ended early")
  end

  defp record_failure(_state), do: :ok

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
        send(consumer, {producer_ref, :chunk, data})

        request
        |> Req.Request.put_private(:claudex_streamed, true)
        |> await_demand(response, producer_ref, consumer_monitor)
      else
        {:cont, {request, %{response | body: response.body <> data}}}
      end
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

  defp outcome({:ok, %Req.Response{status: status} = response}) when status in 200..299,
    do: {:done, %{status: status, request_id: API.request_id(response)}}

  defp outcome({:ok, %Req.Response{status: status, body: body} = response}) do
    {:error, Error.from_response(status, body, API.request_id(response))}
  end

  defp outcome({:error, exception}), do: {:error, Error.from_transport(exception)}
end

defmodule Claudex.ChunkStream do
  @moduledoc false

  alias Claudex.{Client, Error}

  @doc """
  Streams a response body as raw binary chunks.

  Enumerating spawns a process that owns the request and hands chunks over one
  at a time, waiting for the consumer to ask for the next. That wait is the
  backpressure: at most one chunk is read ahead of the consumer, and the socket
  stalls behind it.

  Raises `Claudex.Error` on a non-2xx response, a transport failure, or the
  owning process dying.
  """
  @spec stream(Client.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, request_options) do
    Stream.resource(fn -> connect(client, request_options) end, &next/1, &disconnect/1)
  end

  defp connect(client, request_options) do
    consumer = self()
    ref = make_ref()

    # Test stubs and sandboxes resolve ownership through $callers, and the
    # request runs in a process the caller never sees, so pass the chain on.
    callers = [consumer | Process.get(:"$callers", [])]

    {producer, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        run(client, request_options, consumer, ref)
      end)

    path = Keyword.get(request_options, :url)

    :telemetry.execute([:claudex, :stream, :start], %{system_time: System.system_time()}, %{
      path: path
    })

    %{
      producer: producer,
      monitor: monitor,
      ref: ref,
      done?: false,
      path: path,
      chunks: 0,
      started: System.monotonic_time()
    }
  end

  defp next(%{done?: true} = state), do: {:halt, state}

  defp next(%{ref: ref, monitor: monitor} = state) do
    receive do
      {^ref, :chunk, data} ->
        send(state.producer, {ref, :demand})
        {[data], %{state | chunks: state.chunks + 1}}

      {^ref, :done} ->
        {:halt, %{state | done?: true}}

      {^ref, {:error, error}} ->
        raise error

      {:DOWN, ^monitor, :process, _producer, reason} ->
        raise Error.stream_error("the process running the request exited: #{inspect(reason)}")
    end
  end

  defp disconnect(%{producer: producer, monitor: monitor, ref: ref} = state) do
    send(producer, {ref, :cancel})
    Process.demonitor(monitor, [:flush])
    Process.exit(producer, :kill)

    :telemetry.execute(
      [:claudex, :stream, :stop],
      %{duration: System.monotonic_time() - state.started, chunks: state.chunks},
      %{path: state.path}
    )

    :ok
  end

  defp run(client, request_options, consumer, ref) do
    consumer_monitor = Process.monitor(consumer)

    options =
      Keyword.merge(request_options,
        into: collector(consumer, ref, consumer_monitor),
        retry: &retry_decision/2
      )

    send(consumer, {ref, outcome(Req.request(client.req, options))})
  end

  defp collector(consumer, ref, consumer_monitor) do
    fn {:data, data}, {request, response} ->
      if response.status in 200..299 do
        send(consumer, {ref, :chunk, data})

        request
        |> Req.Request.put_private(:claudex_streamed, true)
        |> await_demand(response, ref, consumer_monitor)
      else
        {:cont, {request, %{response | body: response.body <> data}}}
      end
    end
  end

  defp await_demand(request, response, ref, consumer_monitor) do
    receive do
      {^ref, :demand} -> {:cont, {request, response}}
      {^ref, :cancel} -> {:halt, {request, response}}
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

  defp outcome({:ok, %Req.Response{status: status}}) when status in 200..299, do: :done

  defp outcome({:ok, %Req.Response{status: status, body: body}}) do
    {:error, Error.from_response(status, body)}
  end

  defp outcome({:error, exception}), do: {:error, Error.from_transport(exception)}
end

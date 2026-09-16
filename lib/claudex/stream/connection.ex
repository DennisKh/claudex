defmodule Claudex.Stream.Connection do
  @moduledoc false

  alias Claudex.{ChunkStream, Client, Tracing}
  alias Claudex.Stream.{Accumulator, Event, SSE}
  alias Claudex.Tracing.Attributes

  @doc """
  Returns a lazy stream of events for a streaming Messages request.

  The transport is `Claudex.ChunkStream`; this only turns the bytes it yields
  into typed events.
  """
  @spec stream(Client.t(), map()) :: Enumerable.t()
  @spec stream(Client.t(), map(), reference()) :: Enumerable.t()
  def stream(%Client{} = client, body, cancel_ref \\ make_ref()) do
    client
    |> ChunkStream.stream([method: :post, url: "/v1/messages", json: body], cancel_ref)
    |> Stream.transform(&SSE.new/0, &decode_chunk/2, &flush/1, fn _decoder -> :ok end)
    |> Stream.transform(&recorder/0, &record/2, fn _recorder -> :ok end)
  end

  defp recorder, do: :undecided

  defp record(event, :undecided) do
    if Tracing.enabled?() and Tracing.recording?() do
      record(event, %{accumulator: Accumulator.new(), span: Tracing.current_span()})
    else
      {[event], :untraced}
    end
  end

  defp record(event, :untraced), do: {[event], :untraced}

  defp record(event, state) do
    state = %{state | accumulator: Accumulator.add(state.accumulator, event)}

    if match?(%Event.MessageStop{}, event), do: record_reply(state)

    {[event], state}
  end

  defp record_reply(state) do
    case Accumulator.message(state.accumulator) do
      nil -> :ok
      message -> Tracing.set_attributes(state.span, Attributes.reply(message))
    end
  end

  defp decode_chunk(chunk, decoder) do
    {sse_events, decoder} = SSE.decode(decoder, chunk)

    {events(sse_events), decoder}
  end

  defp flush(decoder) do
    {sse_events, decoder} = SSE.flush(decoder)

    {events(sse_events), decoder}
  end

  defp events(sse_events) do
    Enum.flat_map(sse_events, fn sse_event ->
      case Event.from_sse(sse_event) do
        {:ok, event} -> [event]
        :ignore -> []
        {:error, error} -> raise error
      end
    end)
  end
end

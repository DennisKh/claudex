defmodule Claudex.Stream.Connection do
  @moduledoc false

  alias Claudex.{ChunkStream, Client}
  alias Claudex.Stream.{Event, SSE}

  @doc """
  Returns a lazy stream of events for a streaming Messages request.

  The transport is `Claudex.ChunkStream`; this only turns the bytes it yields
  into typed events.
  """
  @spec stream(Client.t(), map()) :: Enumerable.t()
  def stream(%Client{} = client, body) do
    client
    |> ChunkStream.stream(method: :post, url: "/v1/messages", json: body)
    |> Stream.transform(&SSE.new/0, &decode_chunk/2, &flush/1, fn _decoder -> :ok end)
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

defmodule Claudex.TestSupport.MessageStream do
  @moduledoc """
  Renders a message map as the SSE response the API would have streamed for
  it, so a test can describe a reply once and serve it either way.

  The event shapes follow `test/fixtures/message_stream.sse` and
  `test/fixtures/thinking_stream.sse`: `content` is empty in `message_start`,
  the stop reason arrives in `message_delta`, and the arguments of a call,
  client-side or server-side, arrive as JSON fragments that are only parseable
  once joined.
  """

  @doc "Streams `message` to the connection as `text/event-stream`."
  @spec respond(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def respond(conn, message) do
    Enum.reduce(sse(message), Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  @doc "Returns the SSE events for `message`, one chunk each."
  @spec sse(map()) :: [binary()]
  def sse(message) do
    {content, message} = Map.pop(message, "content")
    {stop_reason, message} = Map.pop(message, "stop_reason")

    [event("message_start", %{"type" => "message_start", "message" => start(message)})] ++
      (content |> Enum.with_index() |> Enum.flat_map(&block/1)) ++
      [
        event("message_delta", %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => stop_reason, "stop_sequence" => nil},
          "usage" => %{"output_tokens" => 5}
        }),
        event("message_stop", %{"type" => "message_stop"})
      ]
  end

  defp start(message) do
    message
    |> Map.put("content", [])
    |> Map.put("stop_reason", nil)
  end

  defp block({%{"type" => "text", "text" => text}, index}) do
    [
      block_start(index, %{"type" => "text", "text" => ""}),
      delta(index, %{"type" => "text_delta", "text" => text}),
      block_stop(index)
    ]
  end

  defp block({%{"input" => input} = tool_use, index}) do
    json = JSON.encode!(input)
    {head, tail} = String.split_at(json, div(String.length(json), 2))

    [block_start(index, %{tool_use | "input" => %{}})] ++
      for fragment <- [head, tail] do
        delta(index, %{"type" => "input_json_delta", "partial_json" => fragment})
      end ++
      [block_stop(index)]
  end

  defp block_start(index, content_block) do
    event("content_block_start", %{
      "type" => "content_block_start",
      "index" => index,
      "content_block" => content_block
    })
  end

  defp delta(index, delta) do
    event("content_block_delta", %{
      "type" => "content_block_delta",
      "index" => index,
      "delta" => delta
    })
  end

  defp block_stop(index) do
    event("content_block_stop", %{"type" => "content_block_stop", "index" => index})
  end

  defp event(name, payload), do: "event: #{name}\ndata: #{JSON.encode!(payload)}\n\n"
end

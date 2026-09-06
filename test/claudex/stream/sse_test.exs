defmodule Claudex.Stream.SSETest do
  use ExUnit.Case, async: true

  alias Claudex.Stream.SSE
  alias Claudex.Stream.SSE.Event

  @message_stream """
  event: message_start
  data: {"type":"message_start","message":{"id":"msg_01","role":"assistant","content":[],"usage":{"input_tokens":10,"output_tokens":1}}}

  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

  event: ping
  data: {"type": "ping"}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}

  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":15}}

  event: message_stop
  data: {"type":"message_stop"}

  """

  defp decode_all(chunks) do
    {events, decoder} =
      Enum.reduce(chunks, {[], SSE.new()}, fn chunk, {events, decoder} ->
        {new_events, decoder} = SSE.decode(decoder, chunk)
        {events ++ new_events, decoder}
      end)

    {trailing, _decoder} = SSE.flush(decoder)
    events ++ trailing
  end

  test "decode/2 returns a complete event" do
    {events, decoder} = SSE.decode(SSE.new(), "event: message_stop\ndata: {}\n\n")

    assert events == [%Event{name: "message_stop", data: "{}"}]
    assert decoder.buffer == ""
  end

  test "decode/2 returns every event in a chunk holding several" do
    {events, _decoder} = SSE.decode(SSE.new(), "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n")

    assert [%Event{name: "a", data: "1"}, %Event{name: "b", data: "2"}] = events
  end

  test "decode/2 holds an event until its terminating blank line arrives" do
    {events, decoder} = SSE.decode(SSE.new(), "event: message_delta\ndata: {\"usa")

    assert events == []

    {events, decoder} = SSE.decode(decoder, "ge\":{\"output_tokens\":15}}\n")

    assert events == []

    {events, _decoder} = SSE.decode(decoder, "\n")

    assert [%Event{name: "message_delta", data: ~s({"usage":{"output_tokens":15}})}] = events
  end

  test "decode/2 accepts CRLF and bare-CR terminators" do
    {crlf, _decoder} = SSE.decode(SSE.new(), "event: a\r\ndata: 1\r\n\r\n")
    {cr, _decoder} = SSE.decode(SSE.new(), "event: b\rdata: 2\r\r")

    assert [%Event{name: "a", data: "1"}] = crlf
    assert [%Event{name: "b", data: "2"}] = cr
  end

  test "decode/2 handles a CRLF terminator split across chunks" do
    {events, decoder} = SSE.decode(SSE.new(), "event: a\r\ndata: 1\r\n\r")

    assert events == []

    {events, _decoder} = SSE.decode(decoder, "\nevent: b\r\ndata: 2\r\n\r\n")

    assert [%Event{name: "a", data: "1"}, %Event{name: "b", data: "2"}] = events
  end

  test "decode/2 joins repeated data fields with a newline" do
    {[event], _decoder} = SSE.decode(SSE.new(), "event: a\ndata: line one\ndata: line two\n\n")

    assert event.data == "line one\nline two"
  end

  test "decode/2 strips one space after the colon and keeps the rest" do
    {[event], _decoder} = SSE.decode(SSE.new(), "data:  two spaces became one\n\n")

    assert event.data == " two spaces became one"
  end

  test "decode/2 treats a field with no colon as an empty value" do
    {[event], _decoder} = SSE.decode(SSE.new(), "event: a\ndata\n\n")

    assert event.data == ""
  end

  test "decode/2 ignores comments and unrecognised fields" do
    chunk = ": keep-alive comment\nevent: a\nfuture_field: value\ndata: 1\n\n"

    {events, _decoder} = SSE.decode(SSE.new(), chunk)

    assert [%Event{name: "a", data: "1"}] = events
  end

  test "decode/2 emits nothing for a block of only comments" do
    assert {[], _decoder} = SSE.decode(SSE.new(), ": keep-alive\n: still here\n\n")
  end

  test "decode/2 reads id and retry, ignoring invalid values" do
    {[event], _decoder} = SSE.decode(SSE.new(), "id: evt_1\nretry: 3000\ndata: 1\n\n")

    assert event.id == "evt_1"
    assert event.retry == 3000

    {[event], _decoder} =
      SSE.decode(SSE.new(), "id: has\0null\nretry: 3 seconds\ndata: 1\n\n")

    assert event.id == nil
    assert event.retry == nil
  end

  test "flush/1 returns an unterminated trailing event" do
    {[], decoder} = SSE.decode(SSE.new(), "event: message_stop\ndata: {}")

    assert {[%Event{name: "message_stop", data: "{}"}], decoder} = SSE.flush(decoder)
    assert decoder.buffer == ""
  end

  test "flush/1 returns nothing for an empty buffer" do
    assert {[], _decoder} = SSE.flush(SSE.new())
  end

  test "decode/2 gives the same events however the bytes are split" do
    expected = decode_all([@message_stream])

    assert length(expected) == 8

    assert Enum.map(expected, & &1.name) ==
             [
               "message_start",
               "content_block_start",
               "ping",
               "content_block_delta",
               "content_block_delta",
               "content_block_stop",
               "message_delta",
               "message_stop"
             ]

    byte_by_byte = decode_all(for <<byte <- @message_stream>>, do: <<byte>>)
    in_sevens = decode_all(chunk_every(@message_stream, 7))

    assert byte_by_byte == expected
    assert in_sevens == expected
  end

  defp chunk_every(binary, size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  test "a block carrying only reconnection fields produces no event" do
    # Its empty data would otherwise reach the typed layer and be rejected as
    # malformed, killing the stream.
    assert {[], _decoder} = SSE.decode(SSE.new(), "retry: 3000\n\n")
    assert {[], _decoder} = SSE.decode(SSE.new(), "id: evt_1\nretry: 3000\n\n")
  end
end

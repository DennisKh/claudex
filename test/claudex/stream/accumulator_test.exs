defmodule Claudex.Stream.AccumulatorTest do
  use ExUnit.Case, async: true

  alias Claudex.ContentBlock
  alias Claudex.Message
  alias Claudex.Stream.{Accumulator, Event}

  defp fold(events), do: Enum.reduce(events, Accumulator.new(), &Accumulator.add(&2, &1))

  defp message_start(usage \\ %{"input_tokens" => 10, "output_tokens" => 1}) do
    Event.decode(%{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_1",
        "role" => "assistant",
        "model" => "claude-opus-5",
        "content" => [],
        "usage" => usage
      }
    })
  end

  defp block_start(index, block) do
    Event.decode(%{"type" => "content_block_start", "index" => index, "content_block" => block})
  end

  defp delta(index, delta) do
    Event.decode(%{"type" => "content_block_delta", "index" => index, "delta" => delta})
  end

  defp block_stop(index), do: Event.decode(%{"type" => "content_block_stop", "index" => index})

  test "message/1 is nil until the stream starts a message" do
    assert Accumulator.message(Accumulator.new()) == nil
    assert Accumulator.message(fold([block_stop(0)])) == nil
  end

  test "add/2 assembles text deltas into a text block" do
    message =
      [
        message_start(),
        block_start(0, %{"type" => "text", "text" => ""}),
        delta(0, %{"type" => "text_delta", "text" => "Hello"}),
        delta(0, %{"type" => "text_delta", "text" => ", world"}),
        block_stop(0),
        Event.decode(%{"type" => "message_stop"})
      ]
      |> fold()
      |> Accumulator.message()

    assert %Message{id: "msg_1", role: "assistant"} = message
    assert Message.text(message) == "Hello, world"
  end

  test "add/2 keeps blocks in index order regardless of arrival order" do
    message =
      [
        message_start(),
        block_start(1, %{"type" => "text", "text" => "second"}),
        block_start(0, %{"type" => "text", "text" => "first "}),
        block_stop(0),
        block_stop(1)
      ]
      |> fold()
      |> Accumulator.message()

    assert Message.text(message) == "first second"
  end

  test "add/2 parses a tool call's arguments once the block stops" do
    events = [
      message_start(),
      block_start(0, %{"type" => "tool_use", "id" => "toolu_1", "name" => "add", "input" => %{}}),
      delta(0, %{"type" => "input_json_delta", "partial_json" => ~s({"a": 1,)}),
      delta(0, %{"type" => "input_json_delta", "partial_json" => ~s( "b": 2})})
    ]

    assert %Message{content: [%ContentBlock.ToolUse{input: %{}}]} =
             events |> fold() |> Accumulator.message()

    assert %Message{content: [%ContentBlock.ToolUse{} = tool_use]} =
             (events ++ [block_stop(0)]) |> fold() |> Accumulator.message()

    assert tool_use.id == "toolu_1"
    assert tool_use.input == %{"a" => 1, "b" => 2}
  end

  test "add/2 leaves a tool call's input alone when the arguments are truncated" do
    message =
      [
        message_start(),
        block_start(0, %{"type" => "tool_use", "id" => "toolu_1", "name" => "add", "input" => %{}}),
        delta(0, %{"type" => "input_json_delta", "partial_json" => ~s({"a": 1,)}),
        block_stop(0)
      ]
      |> fold()
      |> Accumulator.message()

    assert %Message{content: [%ContentBlock.ToolUse{input: %{}}]} = message
  end

  test "add/2 assembles thinking text and its signature" do
    message =
      [
        message_start(),
        block_start(0, %{"type" => "thinking", "thinking" => "", "signature" => ""}),
        delta(0, %{"type" => "thinking_delta", "thinking" => "Let me "}),
        delta(0, %{"type" => "thinking_delta", "thinking" => "count."}),
        delta(0, %{"type" => "signature_delta", "signature" => "abc123"}),
        block_stop(0)
      ]
      |> fold()
      |> Accumulator.message()

    assert %Message{content: [%ContentBlock.Thinking{} = thinking]} = message
    assert thinking.thinking == "Let me count."
    assert thinking.signature == "abc123"
  end

  test "add/2 appends citations to the text block they belong to" do
    message =
      [
        message_start(),
        block_start(0, %{"type" => "text", "text" => "cited"}),
        delta(0, %{"type" => "citations_delta", "citation" => %{"type" => "page_location"}}),
        block_stop(0)
      ]
      |> fold()
      |> Accumulator.message()

    assert %Message{content: [%ContentBlock.Text{citations: [%{"type" => "page_location"}]}]} =
             message
  end

  test "add/2 takes stop details from message_delta and merges usage" do
    message =
      [
        message_start(%{
          "input_tokens" => 10,
          "output_tokens" => 1,
          "cache_read_input_tokens" => 4
        }),
        Event.decode(%{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "max_tokens", "stop_sequence" => "STOP"},
          "usage" => %{"output_tokens" => 15}
        })
      ]
      |> fold()
      |> Accumulator.message()

    assert message.stop_reason == "max_tokens"
    assert message.stop_sequence == "STOP"
    assert message.usage.output_tokens == 15
    assert message.usage.input_tokens == 10
    assert message.usage.cache_read_input_tokens == 4
  end

  test "add/2 ignores a delta for a block that never started" do
    message =
      [message_start(), delta(3, %{"type" => "text_delta", "text" => "orphan"})]
      |> fold()
      |> Accumulator.message()

    assert message.content == []
  end

  test "add/2 ignores an event type it doesn't model" do
    accumulator = fold([message_start(), Event.decode(%{"type" => "future_event"})])

    assert %Message{id: "msg_1"} = Accumulator.message(accumulator)
  end

  test "text/1 renders the reply so far, and an empty string before it starts" do
    assert Accumulator.text(Accumulator.new()) == ""

    accumulator =
      fold([
        message_start(),
        block_start(0, %{"type" => "text", "text" => ""}),
        delta(0, %{"type" => "text_delta", "text" => "Hel"})
      ])

    assert Accumulator.text(accumulator) == "Hel"

    accumulator =
      Accumulator.add(accumulator, delta(0, %{"type" => "text_delta", "text" => "lo"}))

    assert Accumulator.text(accumulator) == "Hello"
    assert Message.text(Accumulator.message(accumulator)) == "Hello"
  end
end

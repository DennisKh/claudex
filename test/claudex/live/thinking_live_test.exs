defmodule Claudex.Live.ThinkingTest do
  @moduledoc """
  End-to-end coverage of extended thinking, streamed and not.

  Claude Haiku 4.5 takes the `budget_tokens` form of the thinking config —
  `adaptive` is not supported on it — and the budget must be at least 1024 and
  below `max_tokens`.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Messages, Stream}
  alias Claudex.Stream.Event

  @budget_tokens 1024
  @max_tokens 2048
  @prompt "How many keystrokes to type the letters of 'banana' on a phone keypad? Think it through."

  test "returns thinking blocks alongside the reply", %{client: client} do
    {:ok, message} =
      client
      |> Recorder.record_json("thinking")
      |> Messages.create(%{
        model: @model,
        max_tokens: @max_tokens,
        thinking: %{type: "enabled", budget_tokens: @budget_tokens},
        messages: [%{role: "user", content: @prompt}]
      })

    thinking = Enum.find(message.content, &match?(%ContentBlock.Thinking{}, &1))

    assert thinking, "expected a thinking block, got: #{inspect(message.content)}"
    assert thinking.thinking != ""
    assert is_binary(thinking.signature) and thinking.signature != ""
  end

  test "streams thinking deltas and the signature that closes the block", %{client: client} do
    events =
      client
      |> Recorder.record_stream("thinking_stream")
      |> Messages.stream!(%{
        model: @model,
        max_tokens: @max_tokens,
        thinking: %{type: "enabled", budget_tokens: @budget_tokens},
        messages: [%{role: "user", content: @prompt}]
      })
      |> Enum.to_list()

    assert Enum.any?(events, &match?(%Event.ContentBlockDelta{delta: {:thinking, _chunk}}, &1))
    assert Enum.any?(events, &match?(%Event.ContentBlockDelta{delta: {:signature, _sig}}, &1))

    {:ok, message} = Stream.final_message(events)
    thinking = Enum.find(message.content, &match?(%ContentBlock.Thinking{}, &1))

    assert thinking.thinking != ""
    assert thinking.signature != ""
  end
end

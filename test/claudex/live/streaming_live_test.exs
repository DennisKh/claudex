defmodule Claudex.Live.StreamingTest do
  @moduledoc """
  End-to-end coverage of both streaming surfaces against the real API.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Message, Messages, Stream}
  alias Claudex.Stream.Event

  test "stream!/2 yields real events that reassemble into the message", %{client: client} do
    events =
      client
      |> Recorder.record_stream("message_stream")
      |> Messages.stream!(%{
        model: @model,
        max_tokens: 64,
        messages: [%{role: "user", content: "Reply with exactly one word: pong"}]
      })
      |> Enum.to_list()

    assert %Event.MessageStart{} = hd(events)
    assert %Event.MessageStop{} = List.last(events)

    streamed = text_of(events)
    assert streamed != ""

    {:ok, message} = Stream.final_message(events)
    assert Message.text(message) == streamed
    assert message.stop_reason in ["end_turn", "max_tokens"]
    assert message.usage.input_tokens > 0
    assert message.usage.output_tokens > 0
  end

  test "stream_to/3 delivers events to a process and finishes with :done", %{client: client} do
    {:ok, handle} =
      Messages.stream_to(client, %{
        model: @model,
        max_tokens: 64,
        messages: [%{role: "user", content: "Reply with exactly one word: pong"}]
      })

    ref = handle.ref

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 60_000
    assert_receive {:claudex, ^ref, {:event, %Event.MessageStop{}}}, 60_000
    assert_receive {:claudex, ^ref, :done}, 60_000
  end

  test "cancel/1 stops a long reply part-way through", %{client: client} do
    {:ok, handle} =
      Messages.stream_to(client, %{
        model: @model,
        max_tokens: 1024,
        messages: [%{role: "user", content: "Count slowly from 1 to 200, one number per line."}]
      })

    ref = handle.ref

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 60_000
    assert_receive {:claudex, ^ref, {:event, %Event.ContentBlockDelta{}}}, 60_000

    assert Stream.cancel(handle) == :ok

    assert_receive {:claudex, ^ref, :cancelled}, 60_000
    refute_receive {:claudex, ^ref, :done}, 1_000
  end

  defp text_of(events) do
    Enum.map_join(events, "", fn
      %Event.ContentBlockDelta{delta: {:text, chunk}} -> chunk
      _event -> ""
    end)
  end

  test "usage merges to the API's running totals, not a sum of them", %{client: client} do
    events =
      client
      |> Messages.stream!(%{
        model: @model,
        max_tokens: 256,
        messages: [%{role: "user", content: "Count from 1 to 30, numbers only."}]
      })
      |> Enum.to_list()

    [%Event.MessageStart{message: %{usage: opening}} | _rest] = events

    reported =
      events
      |> Enum.filter(&match?(%Event.MessageDelta{}, &1))
      |> Enum.map(& &1.usage)

    assert [_at_least_one | _] = reported
    final_report = List.last(reported)

    assert final_report.output_tokens > opening.output_tokens

    {:ok, message} = Stream.final_message(events)

    assert message.usage.output_tokens == final_report.output_tokens

    refute message.usage.output_tokens ==
             opening.output_tokens + Enum.sum(Enum.map(reported, & &1.output_tokens))

    assert message.usage.input_tokens > 0
    assert message.usage.input_tokens == opening.input_tokens
  end
end

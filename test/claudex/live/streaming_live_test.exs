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

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 10_000
    assert_receive {:claudex, ^ref, {:event, %Event.MessageStop{}}}, 5_000
    assert_receive {:claudex, ^ref, :done}, 5_000
  end

  test "cancel/1 stops a long reply part-way through", %{client: client} do
    {:ok, handle} =
      Messages.stream_to(client, %{
        model: @model,
        max_tokens: 1024,
        messages: [%{role: "user", content: "Count slowly from 1 to 200, one number per line."}]
      })

    ref = handle.ref

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 10_000
    assert_receive {:claudex, ^ref, {:event, %Event.ContentBlockDelta{}}}, 5_000

    assert Stream.cancel(handle) == :ok

    assert_receive {:claudex, ^ref, :cancelled}, 5_000
    refute_receive {:claudex, ^ref, :done}, 1_000
  end

  describe "stream_to/3 with :every" do
    test "batches a real reply, its first window opening with the first event",
         %{client: client} do
      {:ok, handle} =
        Messages.stream_to(
          client,
          %{
            model: @model,
            max_tokens: 64,
            messages: [%{role: "user", content: "Reply with exactly one word: pong"}]
          },
          every: 250
        )

      [first | _rest] = batches = collect_batches(handle.ref, [])
      events = List.flatten(batches)

      assert [%Event.MessageStart{}, _next | _] = first
      assert %Event.MessageStop{} = List.last(events)
      assert text_of(events) != ""
    end

    test "a cancel mid-window delivers the buffered events, then :cancelled",
         %{client: client} do
      {:ok, handle} =
        Messages.stream_to(
          client,
          %{
            model: @model,
            max_tokens: 8_000,
            messages: [
              %{
                role: "user",
                content:
                  "Count from 1 to 2000, one number per line. " <>
                    "Write every number; don't skip or abbreviate."
              }
            ]
          },
          every: 500
        )

      ref = handle.ref

      assert_receive {:claudex, ^ref, {:events, [%Event.MessageStart{} | _rest]}}, 10_000

      Process.sleep(200)
      assert Stream.cancel(handle) == :ok

      assert_receive {:claudex, ^ref, {:events, [_event | _rest]}}, 5_000

      assert_receive {:claudex, ^ref, ending}
                     when ending in [:cancelled, :done] or
                            (is_tuple(ending) and elem(ending, 0) == :error),
                     5_000

      assert ending == :cancelled
    end
  end

  defp collect_batches(ref, batches) do
    receive do
      {:claudex, ^ref, {:events, events}} -> collect_batches(ref, [events | batches])
      {:claudex, ^ref, :done} -> Enum.reverse(batches)
    after
      60_000 -> flunk("the stream never finished")
    end
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

  test "a programmatic tool call carried by message_start reassembles into the message",
       %{client: client} do
    tools = [
      %{
        name: "revenue",
        description: "Returns the revenue in dollars for a customer id such as C1, C2 or C3.",
        input_schema: %{
          type: "object",
          properties: %{id: %{type: "string"}},
          required: ["id"]
        },
        allowed_callers: ["code_execution_20260120"]
      },
      %{type: "code_execution_20260120", name: "code_execution"}
    ]

    question =
      Message.user(
        "Write Python code that calls revenue for C1, then C2, then C3 sequentially " <>
          "(from code, not directly) and prints the total. Then tell me the total."
      )

    params = %{model: "claude-haiku-5-5", max_tokens: 1500, tools: tools}

    {:ok, first} = Messages.create(client, Map.put(params, :messages, [question]))
    [call] = Message.tool_uses(first)

    history =
      Message.append([question], [first, Message.tool_results([Claudex.Tool.result(call, "100")])])

    events =
      client
      |> Recorder.record_stream("programmatic_tool_call_stream")
      |> Messages.stream!(
        Map.merge(params, %{messages: history, container: first.container["id"]})
      )
      |> Enum.to_list()

    assert [%Event.MessageStart{message: %{content: [_call | _rest]}} | _events] = events
    refute Enum.any?(events, &match?(%Event.ContentBlockStart{}, &1))

    {:ok, message} = Stream.final_message(events)

    assert message.stop_reason == "tool_use"
    assert [%{name: "revenue", input: %{"id" => "C2"}}] = Message.tool_uses(message)
  end
end

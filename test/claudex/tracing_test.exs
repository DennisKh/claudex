defmodule Claudex.TracingTest do
  @moduledoc """
  Spans are exported to this process instead of an OTLP endpoint, so a test
  can assert on what was actually recorded rather than on the call that
  recorded it.
  """

  use ExUnit.Case, async: false

  require Record

  alias Claudex.{Client, Messages, ToolRunner, Tracing}
  alias Claudex.TestSupport.MessageStream

  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  @params %{
    model: "claude-haiku-4-5",
    max_tokens: 64,
    messages: [%{role: "user", content: "What is 12 plus 30?"}]
  }

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> Application.delete_env(:claudex, :trace_content) end)

    :ok
  end

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp reply(body) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
  end

  # The runner always streams, so a stub that answers it has to as well.
  defp stream_reply(body) do
    Req.Test.stub(__MODULE__, fn conn -> MessageStream.respond(conn, body) end)
  end

  defp message do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5-20251001",
      "content" => [%{"type" => "text", "text" => "42"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 15, "output_tokens" => 6}
    }
  end

  defp attributes(span(attributes: attributes)) do
    {:attributes, _count, _type, _dropped, map} = attributes

    map
  end

  test "a message request records the GenAI attributes a backend reads" do
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params)

    assert_receive {:span, recorded}, 2_000

    assert span(recorded, :name) == "chat claude-haiku-4-5"

    assert %{
             "gen_ai.system" => "anthropic",
             "gen_ai.operation.name" => "chat",
             "gen_ai.request.model" => "claude-haiku-4-5",
             "gen_ai.request.max_tokens" => 64,
             "gen_ai.response.id" => "msg_1",
             "gen_ai.response.model" => "claude-haiku-4-5-20251001",
             "gen_ai.response.finish_reasons" => ["end_turn"],
             "gen_ai.usage.input_tokens" => 15,
             "gen_ai.usage.output_tokens" => 6,
             "http.response.status_code" => 200
           } = attributes(recorded)
  end

  test "the request and response models are both recorded, because they differ" do
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params)
    assert_receive {:span, recorded}, 2_000

    recorded = attributes(recorded)

    # A request naming an alias comes back naming a snapshot. A trace that kept
    # only one of them could not tell you which model actually answered.
    assert recorded["gen_ai.request.model"] == "claude-haiku-4-5"
    assert recorded["gen_ai.response.model"] == "claude-haiku-4-5-20251001"
  end

  test "message content is left out unless the app asks for it" do
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params)
    assert_receive {:span, recorded}, 2_000

    recorded = attributes(recorded)

    refute Map.has_key?(recorded, "gen_ai.prompt")
    refute Map.has_key?(recorded, "gen_ai.completion")
  end

  test "trace_content: true puts the prompt and the completion on the span" do
    Application.put_env(:claudex, :trace_content, true)
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params)
    assert_receive {:span, recorded}, 2_000

    recorded = attributes(recorded)

    assert recorded["gen_ai.prompt"] =~ "What is 12 plus 30?"
    assert recorded["gen_ai.completion"] =~ "42"
  end

  test "a failed request marks the span as an error" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}})
    end)

    assert {:error, _error} = Messages.create(client(), @params)
    assert_receive {:span, recorded}, 2_000

    assert {:status, :error, "slow down"} = span(recorded, :status)
    assert attributes(recorded)["http.response.status_code"] == 429
  end

  test "an endpoint with no model is a plain HTTP span, not a generation" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [], "has_more" => false})
    end)

    assert {:ok, _page} = Claudex.Models.list(client())
    assert_receive {:span, recorded}, 2_000

    assert span(recorded, :name) == "GET /v1/models"
    refute Map.has_key?(attributes(recorded), "gen_ai.system")
  end

  defmodule Calculator do
    use Claudex.Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b), do: a + b
  end

  test "a tool conversation nests its requests and tool calls under each turn" do
    replies = [
      %{
        message()
        | "content" => [
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "add",
              "input" => %{"a" => 12, "b" => 30}
            }
          ],
          "stop_reason" => "tool_use"
      },
      message()
    ]

    {:ok, counter} = Agent.start_link(fn -> replies end)

    Req.Test.stub(__MODULE__, fn conn ->
      reply = Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)

      MessageStream.respond(conn, reply)
    end)

    assert {:ok, _turn} =
             ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    spans = collect_spans([])

    # The whole point: a run is one trace. Without a span around the
    # conversation every turn is its own root, and a backend shows a
    # two-turn run as two unrelated traces.
    assert spans |> Enum.map(&span(&1, :trace_id)) |> Enum.uniq() |> length() == 1
    assert [root] = Enum.filter(spans, &(span(&1, :parent_span_id) == :undefined))
    assert span(root, :name) == "invoke_agent claude-haiku-4-5"

    # Every turn carries the same name so a backend can fold them into one
    # node; the index tells them apart.
    turns = named(spans, "turn")
    assert length(turns) == 2

    first_turn = Enum.find(turns, &(attributes(&1)["claudex.turn.index"] == 1))
    second_turn = Enum.find(turns, &(attributes(&1)["claudex.turn.index"] == 2))
    [tool] = named(spans, "execute_tool add")
    requests = named(spans, "chat claude-haiku-4-5")
    assert length(requests) == 2

    # The operation names are the ones the conventions define, so a backend
    # classifies each span instead of showing an unrecognised one.
    assert attributes(root)["gen_ai.operation.name"] == "invoke_agent"
    assert attributes(tool)["gen_ai.operation.name"] == "execute_tool"
    assert attributes(tool)["gen_ai.tool.name"] == "add"
    assert Enum.all?(requests, &(attributes(&1)["gen_ai.operation.name"] == "chat"))

    # Every turn hangs off the conversation, and every request and tool call
    # off the turn it belongs to.
    assert span(first_turn, :parent_span_id) == span(root, :span_id)
    assert span(second_turn, :parent_span_id) == span(root, :span_id)
    assert span(tool, :parent_span_id) == span(first_turn, :span_id)

    turn_ids = MapSet.new(turns, &span(&1, :span_id))
    assert Enum.all?(requests, &MapSet.member?(turn_ids, span(&1, :parent_span_id)))
    assert attributes(first_turn)["claudex.turn.index"] == 1
  end

  defp named(spans, name), do: Enum.filter(spans, &(span(&1, :name) == name))

  defp collect_spans(collected) do
    receive do
      {:span, recorded} -> collect_spans([recorded | collected])
    after
      200 -> collected
    end
  end

  test "a named session lands on the conversation span, not on the turns" do
    stream_reply(message())

    assert {:ok, _turn} =
             ToolRunner.run(client(), Map.put(@params, :tools, Calculator),
               session: "chat-018f3c21"
             )

    spans = collect_spans([])
    [root] = Enum.filter(spans, &(span(&1, :parent_span_id) == :undefined))

    assert attributes(root)["session.id"] == "chat-018f3c21"

    # One id on the trace is what a backend groups by. Repeating it on every
    # span would say the same thing several times.
    assert Enum.count(spans, &Map.has_key?(attributes(&1), "session.id")) == 1
  end

  test "without a session the conversation span carries no id" do
    stream_reply(message())

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    spans = collect_spans([])

    refute Enum.any?(spans, &Map.has_key?(attributes(&1), "session.id"))
  end

  test "every turn shares one span name, so a backend folds them into one node" do
    replies = [
      %{
        message()
        | "content" => [
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "add",
              "input" => %{"a" => 1, "b" => 2}
            }
          ],
          "stop_reason" => "tool_use"
      },
      %{
        message()
        | "content" => [
            %{
              "type" => "tool_use",
              "id" => "t2",
              "name" => "add",
              "input" => %{"a" => 3, "b" => 4}
            }
          ],
          "stop_reason" => "tool_use"
      },
      message()
    ]

    {:ok, counter} = Agent.start_link(fn -> replies end)

    Req.Test.stub(__MODULE__, fn conn ->
      MessageStream.respond(
        conn,
        Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)
      )
    end)

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    turns = named(collect_spans([]), "turn")

    # Three turns, one name. An index in the name would make each turn its own
    # node in an aggregated graph, so a five-turn run would draw five of them.
    assert length(turns) == 3
    assert turns |> Enum.map(&attributes(&1)["claudex.turn.index"]) |> Enum.sort() == [1, 2, 3]
  end

  test "the conversation span carries the run's own question and answer" do
    Application.put_env(:claudex, :trace_content, true)

    replies = [
      %{
        message()
        | "content" => [
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "add",
              "input" => %{"a" => 12, "b" => 30}
            }
          ],
          "stop_reason" => "tool_use"
      },
      message()
    ]

    {:ok, counter} = Agent.start_link(fn -> replies end)

    Req.Test.stub(__MODULE__, fn conn ->
      MessageStream.respond(
        conn,
        Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)
      )
    end)

    params =
      @params
      |> Map.put(:tools, Calculator)
      |> Map.put(:system, "You are a calculator.")

    assert {:ok, _turn} = ToolRunner.run(client(), params)

    spans = collect_spans([])
    [root] = Enum.filter(spans, &(span(&1, :parent_span_id) == :undefined))
    recorded = attributes(root)

    # A trace's input and output are the run's, not the last request's. Without
    # them a session page has nothing to show for the whole conversation.
    assert [%{"role" => "system"}, %{"role" => "user"}] = JSON.decode!(recorded["gen_ai.prompt"])
    assert recorded["gen_ai.completion"] =~ "42"
    assert recorded["claudex.stop"] == "completed"

    assert [%{"type" => "function", "name" => "add"}] =
             JSON.decode!(recorded["gen_ai.tool.definitions"])
  end

  test "a turn is a grouping span, not a generation" do
    stream_reply(message())

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    [turn] = named(collect_spans([]), "turn")

    # A backend reads a model attribute as "this is a generation". The
    # generation is the chat span inside the turn, not the turn.
    refute Map.has_key?(attributes(turn), "gen_ai.request.model")
    refute Map.has_key?(attributes(turn), "gen_ai.operation.name")
  end

  test "a tool call records its arguments and its result when content is on" do
    Application.put_env(:claudex, :trace_content, true)

    replies = [
      %{
        message()
        | "content" => [
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "add",
              "input" => %{"a" => 12, "b" => 30}
            }
          ],
          "stop_reason" => "tool_use"
      },
      message()
    ]

    {:ok, counter} = Agent.start_link(fn -> replies end)

    Req.Test.stub(__MODULE__, fn conn ->
      MessageStream.respond(
        conn,
        Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)
      )
    end)

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    [tool] = named(collect_spans([]), "execute_tool add")
    recorded = attributes(tool)

    assert recorded["gen_ai.tool.type"] == "function"
    assert recorded["gen_ai.tool.call.arguments"] =~ ~s("a":12)
    assert recorded["gen_ai.tool.call.result"] == "42"

    # The conventions' names are the correct ones; these are what a backend
    # reads for an observation's input and output.
    assert recorded["gen_ai.prompt"] == recorded["gen_ai.tool.call.arguments"]
    assert recorded["gen_ai.completion"] == recorded["gen_ai.tool.call.result"]
  end

  test "a tool call records nothing of its arguments when content is off" do
    stream_reply(message())

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    for span <- collect_spans([]) do
      refute Map.has_key?(attributes(span), "gen_ai.tool.call.arguments")
    end
  end

  test "a streamed reply records the model, the tokens and the stop reason" do
    stream_reply(message())

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    [request] = named(collect_spans([]), "chat claude-haiku-4-5")
    recorded = attributes(request)

    # A streamed request has no response body, so every one of these exists
    # only in the events. Without reading them back a tool conversation
    # reports no tokens and no answer at all.
    assert recorded["gen_ai.response.model"] == "claude-haiku-4-5-20251001"
    assert recorded["gen_ai.response.id"] == "msg_1"
    assert recorded["gen_ai.usage.input_tokens"] == 15
    assert recorded["gen_ai.usage.output_tokens"] == 5
    assert recorded["gen_ai.response.finish_reasons"] == ["end_turn"]
  end

  test "a streamed reply records its content when content is on" do
    Application.put_env(:claudex, :trace_content, true)
    stream_reply(message())

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    [request] = named(collect_spans([]), "chat claude-haiku-4-5")
    recorded = attributes(request)

    assert recorded["gen_ai.completion"] =~ "42"

    # The conventions' message shape: a role with typed parts, which is what
    # lets a backend render a reply rather than print a blob.
    assert [%{"role" => "assistant", "parts" => [%{"type" => "text", "content" => "42"}]}] =
             JSON.decode!(recorded["gen_ai.output.messages"])
  end

  test "a reply asking for a tool says so in the shape a reader parses" do
    Application.put_env(:claudex, :trace_content, true)

    replies = [
      %{
        message()
        | "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "add",
              "input" => %{"a" => 5, "b" => 3}
            }
          ],
          "stop_reason" => "tool_use"
      },
      message()
    ]

    {:ok, counter} = Agent.start_link(fn -> replies end)

    Req.Test.stub(__MODULE__, fn conn ->
      MessageStream.respond(
        conn,
        Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)
      )
    end)

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    asking =
      collect_spans([])
      |> named("chat claude-haiku-4-5")
      |> Enum.find(&(attributes(&1)["gen_ai.response.finish_reasons"] == ["tool_use"]))

    assert asking, "expected a reply that stopped to ask for a tool"
    recorded = attributes(asking)

    # Claude asks for a tool with a tool_use content block. A reader of
    # gen_ai.completion has no reason to know that shape, so a reply asking
    # for a tool would read as one asking for nothing.
    assert %{"role" => "assistant", "tool_calls" => [call]} =
             JSON.decode!(recorded["gen_ai.completion"])

    assert call["name"] == "add"
    assert call["id"] == "toolu_1"
    assert call["args"] == %{"a" => 5, "b" => 3}

    # The conventions' own attribute keeps its own shape.
    assert [%{"parts" => [%{"type" => "tool_call", "name" => "add"}]}] =
             JSON.decode!(recorded["gen_ai.output.messages"])
  end

  test "the request records the system prompt and the tools separately" do
    Application.put_env(:claudex, :trace_content, true)
    stream_reply(message())

    params =
      @params
      |> Map.put(:tools, Calculator)
      |> Map.put(:system, "You are a calculator.")

    assert {:ok, _turn} = ToolRunner.run(client(), params)

    [request] = named(collect_spans([]), "chat claude-haiku-4-5")
    recorded = attributes(request)

    # The conventions keep the system prompt out of the chat history, and the
    # tools the model was offered are their own attribute.
    assert [%{"type" => "text", "content" => "You are a calculator."}] =
             JSON.decode!(recorded["gen_ai.system_instructions"])

    assert [%{"type" => "function", "name" => "add"}] =
             JSON.decode!(recorded["gen_ai.tool.definitions"])

    assert [%{"role" => "user", "parts" => [%{"type" => "text"}]}] =
             JSON.decode!(recorded["gen_ai.input.messages"])

    # The conventions keep it apart; the legacy attribute's readers expect it
    # at the front of the conversation, so it goes in both places.
    assert [%{"role" => "system", "content" => "You are a calculator."} | _rest] =
             JSON.decode!(recorded["gen_ai.prompt"])
  end

  test "the span hands back what the work returned" do
    assert Tracing.span("work", %{}, fn -> :the_result end) == :the_result
  end

  test "an exception in the work is recorded on the span and re-raised unchanged" do
    assert_raise RuntimeError, "boom", fn ->
      Tracing.span("work", %{}, fn -> raise "boom" end)
    end

    assert_receive {:span, recorded}, 2_000

    assert {:status, :error, "boom"} = span(recorded, :status)
    assert {:events, _count, _limit, _type, _dropped, [event]} = span(recorded, :events)

    {:event, _time, :exception, {:attributes, _n, _t, _d, recorded_attributes}} = event

    assert recorded_attributes["exception.type"] == "RuntimeError"
    assert recorded_attributes["exception.message"] == "boom"
  end
end

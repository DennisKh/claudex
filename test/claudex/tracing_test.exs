defmodule Claudex.TracingTest do
  @moduledoc """
  Spans are exported to this process instead of an OTLP endpoint, so a test
  can assert on what was actually recorded rather than on the call that
  recorded it.
  """

  use ExUnit.Case, async: false

  require Record

  alias Claudex.{Client, Files, Messages, Tool, ToolRunner, Tracing}
  alias Claudex.{Client, Files, Messages, Tool, ToolRunner, Tracing}
  alias Claudex.Stream.Event
  alias Claudex.TestSupport.{Fixtures, MessageStream}
  alias Claudex.TestSupport.{Fixtures, MessageStream}
  alias Claudex.Tracing.Attributes

  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  @params %{
    model: "claude-haiku-4-5",
    max_tokens: 64,
    messages: [%{role: "user", content: "What is 12 plus 30?"}]
  }

  setup do
    # The exporter is global to the VM and there is no way to unset it: every
    # set_exporter arity wraps its argument in a tuple, so :none reaches
    # otel_exporter:init/1 as {:none, []} and it tries to call none:init/1.
    # Left pointing at a finished test's pid it sends into a dead process,
    # which is a no-op, and config/config.exs sets traces_exporter: :none for
    # this environment anyway, so a file that sets none of its own exports
    # nowhere either way.
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

  test "a named session lands on the conversation span and every request inside it" do
  test "a named session lands on the conversation span and every request inside it" do
    stream_reply(message())

    assert {:ok, _turn} =
             ToolRunner.run(client(), Map.put(@params, :tools, Calculator),
               session: "chat-018f3c21"
             )

    spans = collect_spans([])
    [root] = Enum.filter(spans, &(span(&1, :parent_span_id) == :undefined))
    [request] = named(spans, "chat claude-haiku-4-5")
    [turn] = named(spans, "turn")
    [request] = named(spans, "chat claude-haiku-4-5")
    [turn] = named(spans, "turn")

    assert attributes(root)["session.id"] == "chat-018f3c21"

    assert attributes(request)["session.id"] == "chat-018f3c21"
    refute Map.has_key?(attributes(turn), "session.id")
  end

  test "two runs interleaved in one process keep their own session and leave none behind" do
    stream_reply(message())

    a = ToolRunner.stream(client(), @params, session: "chat-a")
    b = ToolRunner.stream(client(), @params, session: "chat-b")

    a |> Stream.zip(b) |> Enum.to_list()

    spans = collect_spans([])

    assert spans
           |> named("invoke_agent claude-haiku-4-5")
           |> Enum.map(&attributes(&1)["session.id"])
           |> Enum.sort() == ["chat-a", "chat-b"]

    assert spans
           |> named("chat claude-haiku-4-5")
           |> Enum.map(&attributes(&1)["session.id"])
           |> Enum.sort() == ["chat-a", "chat-b"]

    assert Tracing.session_id() == nil
  end

  test "a run started with :session leaves no session behind for the next one" do
    stream_reply(message())

    assert {:ok, _turn} =
             ToolRunner.run(client(), Map.put(@params, :tools, Calculator),
               session: "chat-018f3c21"
             )

    assert Tracing.session_id() == nil
  end

  test "without a session the conversation span carries no id" do
    stream_reply(message())

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    spans = collect_spans([])

    refute Enum.any?(spans, &Map.has_key?(attributes(&1), "session.id"))
  end

  test "create/3 names the conversation for one call" do
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params, session: "chat-per-call")

    assert_receive {:span, recorded}, 2_000
    assert attributes(recorded)["session.id"] == "chat-per-call"
    assert Tracing.session_id() == nil, "a per-call session must not outlive the call"
  end

  test "count_tokens/3 names the conversation for one call" do
    reply(%{"input_tokens" => 12})

    assert {:ok, 12} =
             Messages.count_tokens(client(), Map.delete(@params, :max_tokens),
               session: "chat-counted"
             )

    assert_receive {:span, recorded}, 2_000
    assert attributes(recorded)["session.id"] == "chat-counted"
  end

  test "stream!/3 names the conversation for one call" do
    stream_reply(message())

    client() |> Messages.stream!(@params, session: "chat-streamed") |> Enum.to_list()

    [request] = named(collect_spans([]), "chat claude-haiku-4-5")
    assert attributes(request)["session.id"] == "chat-streamed"
  end

  test "stream_to/3 names the conversation for one call, across the spawn" do
    stream_reply(message())

    {:ok, handle} = Messages.stream_to(client(), @params, session: "chat-forwarded-opt")
    ref = handle.ref
    assert_receive {:claudex, ^ref, :done}, 2_000

    [request] = named(collect_spans([]), "chat claude-haiku-4-5")
    assert attributes(request)["session.id"] == "chat-forwarded-opt"
  end

  test "a session passed to a call wins over the one set for the process" do
    reply(message())
    Tracing.set_session("chat-ambient")

    assert {:ok, _message} = Messages.create(client(), @params, session: "chat-explicit")

    assert_receive {:span, recorded}, 2_000
    assert attributes(recorded)["session.id"] == "chat-explicit"
    assert Tracing.session_id() == "chat-ambient", "the call must not disturb the process"
  end

  test "a tool call's span carries the session named for the process" do
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
      message()
    ]

    {:ok, counter} = Agent.start_link(fn -> replies end)

    Req.Test.stub(__MODULE__, fn conn ->
      reply = Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)
      MessageStream.respond(conn, reply)
    end)

    Tracing.set_session("chat-tooled")

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    [tool] = named(collect_spans([]), "execute_tool add")
    assert attributes(tool)["session.id"] == "chat-tooled"
  end

  test "Tool.call/4 names the conversation for one call" do
    span = Tracing.start_conversation(@params, session: "chat-hand-tools")

    assert {:ok, 3} =
             Tool.call(Calculator, "add", %{"a" => 1, "b" => 2}, session: "chat-hand-tools")

    Tracing.end_conversation(span)

    [tool] = named(collect_spans([]), "execute_tool add")
    assert attributes(tool)["session.id"] == "chat-hand-tools"
  end

  test "a session passed to a tool call wins over the one set for the process" do
    Tracing.set_session("chat-ambient")

    assert {:ok, 3} =
             Tool.call(Calculator, "add", %{"a" => 1, "b" => 2}, session: "chat-explicit")

    assert_receive {:span, recorded}, 2_000
    assert attributes(recorded)["session.id"] == "chat-explicit"
    assert Tracing.session_id() == "chat-ambient"
  end

  test "a row id becomes a session id rather than being dropped" do
    assert Tracing.set_session(12_345) == :ok
    assert Tracing.session_id() == "12345"
  end

  test "a value with no string form leaves the run alone instead of ending it" do
    stream_reply(message())

    Tracing.set_session("chat-kept")
    assert Tracing.set_session(%{id: 1}) == :ok
    assert Tracing.session_id() == "chat-kept"

    assert {:ok, _turn} =
             ToolRunner.run(client(), Map.put(@params, :tools, Calculator), session: %{id: 1})
  end

  test "an upload names the conversation the attachment belongs to" do
    reply(Fixtures.json!("file"))

    assert {:ok, _file} =
             Files.upload(client(), {"hello", "note.txt"}, session: "chat-attached")

    assert_receive {:span, recorded}, 2_000
    assert span(recorded, :name) == "POST /v1/files"
    assert attributes(recorded)["session.id"] == "chat-attached"
  end

  test "an integer session on a call reaches the span as a string" do
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params, session: 4_242)

    assert_receive {:span, recorded}, 2_000
    assert attributes(recorded)["session.id"] == "4242"
  end

  test "the conversation span picks up the session named for the process" do
    stream_reply(message())
    Tracing.set_session("chat-ambient-root")

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    [conversation] = named(collect_spans([]), "invoke_agent claude-haiku-4-5")
    assert attributes(conversation)["session.id"] == "chat-ambient-root"
  end

  test "start_conversation/2 groups a hand-driven loop into one trace" do
    reply(message())

    span = Tracing.start_conversation(@params, session: "chat-by-hand")
    assert {:ok, reply} = Messages.create(client(), @params, session: "chat-by-hand")
    Tracing.end_conversation(span, reply, :completed)

    spans = collect_spans([])

    [conversation] = named(spans, "invoke_agent claude-haiku-4-5")
    [request] = named(spans, "chat claude-haiku-4-5")

    assert span(request, :parent_span_id) == span(conversation, :span_id)
    assert span(request, :trace_id) == span(conversation, :trace_id)

    assert attributes(conversation)["session.id"] == "chat-by-hand"
    assert attributes(conversation)["claudex.stop"] == "completed"
  end

  test "a conversation that ended before any content still records why" do
    span = Tracing.start_conversation(@params, session: "chat-cancelled")
    Tracing.end_conversation(span, nil, :cancelled)

    assert_receive {:span, recorded}, 2_000
    assert attributes(recorded)["claudex.stop"] == "cancelled"
    assert attributes(recorded)["session.id"] == "chat-cancelled"
  end

  test "a conversation with no turn limit records no turn limit" do
    span = Tracing.start_conversation(@params)
    Tracing.end_conversation(span)

    assert_receive {:span, recorded}, 2_000
    refute Map.has_key?(attributes(recorded), "claudex.turn.max")
    refute Map.has_key?(attributes(recorded), "claudex.stop")
  end

  test "set_session/1 names spans built afterward, and nil clears it" do
    assert Tracing.session_id() == nil

    Tracing.set_session("chat-1")
    assert Tracing.session_id() == "chat-1"

    Tracing.set_session(nil)
    assert Tracing.session_id() == nil
  end

  test "set_session(nil) clears the session key without touching other baggage" do
    :otel_baggage.set("user.id", "u-1")
    Tracing.set_session("chat-1")

    Tracing.set_session(nil)

    assert :otel_baggage.get_all() == %{"user.id" => {"u-1", []}}
  end

  test "a run started with :session restores whatever session was ambient before it" do
    Tracing.set_session("outer-chat")
    stream_reply(message())

    assert {:ok, _turn} =
             ToolRunner.run(client(), Map.put(@params, :tools, Calculator), session: "inner-chat")

    assert Tracing.session_id() == "outer-chat"
  end

  test "a request carries no session.id key when none is set" do
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params)
    assert_receive {:span, recorded}, 2_000

    refute Map.has_key?(attributes(recorded), "session.id")
  end

  test "a caller driving its own loop names a create/2 span with set_session/1" do
    Tracing.set_session("chat-standalone")
    reply(message())

    assert {:ok, _message} = Messages.create(client(), @params)
    assert_receive {:span, recorded}, 2_000

    assert attributes(recorded)["session.id"] == "chat-standalone"
  end

  test "set_session/1 crosses into the process stream_to/3 spawns" do
    Tracing.set_session("chat-forwarded")
    stream_reply(message())

    {:ok, handle} = Messages.stream_to(client(), @params)
    ref = handle.ref
    assert_receive {:claudex, ^ref, :done}, 2_000

    [request] = named(collect_spans([]), "chat claude-haiku-4-5")
    assert attributes(request)["session.id"] == "chat-forwarded"
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
    assert recorded["gen_ai.usage.output_tokens"] == 6
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

  test "nothing outside Claudex.Tracing calls OpenTelemetry directly" do
    # Tracing is optional: an app that adds no SDK gets a no-op tracer, and
    # every call into it here is wrapped so a broken one cannot fail a
    # request. That only holds while the calls stay in one module.
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == "lib/claudex/tracing.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/:otel_\w+\.|:opentelemetry\./))

    assert offenders == [],
           "these reach OpenTelemetry without going through Claudex.Tracing: #{inspect(offenders)}"
  end

  test "the handles a stream holds when it is not tracing go back in unharmed" do
    # An app with no SDK is checked by `mix test.no_otel`, which runs in :prod
    # where the SDK is absent. The test environment has it, so this covers the
    # other half: the values the code itself passes around when a stream found
    # nothing to record.
    assert Tracing.set_attributes(:untraced, %{"a" => 1}) == :ok
    assert Tracing.end_span(:untraced) == :ok
    assert Tracing.attach(:undefined) == :ok
  end

  test "a caller's own spans stay free of Claudex's attributes" do
    require OpenTelemetry.Tracer, as: Tracer

    stream_reply(message())

    # What a LiveView rendering deltas does: pull an event, do its own traced
    # work, pull the next. An app's span must not collect our attributes, and
    # a reply must land on the request that produced it whatever is current
    # by the time it finishes.
    client()
    |> Messages.stream!(@params)
    |> Enum.each(fn _event ->
      Tracer.with_span "my_app.render" do
        :ok
      end
    end)

    spans = collect_spans([])

    for app_span <- named(spans, "my_app.render") do
      assert attributes(app_span) == %{}
    end

    [request] = named(spans, "chat claude-haiku-4-5")
    assert attributes(request)["gen_ai.usage.input_tokens"] == 15
    assert attributes(request)["gen_ai.response.model"] == "claude-haiku-4-5-20251001"
  end

  test "a reply lands on its own request even if a caller left a span open" do
    stream_reply(message())

    # Not every app scopes its spans. One that starts a span in one callback
    # and ends it in another leaves something else current when our reply
    # finishes, and the tokens still belong to the request that earned them.
    leaked =
      client()
      |> Messages.stream!(@params)
      |> Enum.reduce(nil, fn
        %Event.ContentBlockStop{}, nil ->
          tracer = :opentelemetry.get_application_tracer(__MODULE__)
          ctx = :otel_tracer.start_span(tracer, "my_app.unclosed", %{})
          :otel_tracer.set_current_span(ctx)
          ctx

        _event, held ->
          held
      end)

    :otel_span.end_span(leaked)

    spans = collect_spans([])

    [request] = named(spans, "chat claude-haiku-4-5")
    assert attributes(request)["gen_ai.usage.input_tokens"] == 15

    [app_span] = named(spans, "my_app.unclosed")
    assert attributes(app_span) == %{}
  end

  test "content JSON refuses does not raise where the attributes are built" do
    Application.put_env(:claudex, :trace_content, true)

    # Attributes are built as an argument at the call sites, outside every
    # tracer guard, so anything that raises in here reaches the caller. A tool
    # that hands back bytes is the realistic way to get there.
    bytes = <<0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE>>

    assert %{"gen_ai.tool.call.result" => recorded} =
             Attributes.tool_outcome(:ok, {:ok, bytes})

    assert recorded =~ "137"
    assert String.valid?(recorded)

    # Anything else a tool might return, none of which JSON encodes either.
    for value <- [self(), {:error, :nope}, make_ref()] do
      assert %{"gen_ai.tool.call.result" => _encoded} =
               Attributes.tool_outcome(:ok, {:ok, value})
    end
  end

  test "stream_to/3 joins the caller's trace rather than starting its own" do
    require OpenTelemetry.Tracer, as: Tracer

    stream_reply(message())

    # The loop runs in a process of its own, and a span is found through the
    # process dictionary. Without the context going with it, a caller that
    # wrapped the run in its own span gets two unrelated traces.
    {:ok, handle} =
      Tracer.with_span "my_app.handle_message" do
        {:ok, handle} =
          ToolRunner.stream_to(client(), Map.put(@params, :tools, Calculator), to: self())

        ref = handle.ref
        assert_receive {:claudex, ^ref, :done}, 2_000

        {:ok, handle}
      end

    assert %Claudex.Stream.Handle{} = handle

    spans = collect_spans([])
    traces = spans |> Enum.map(&span(&1, :trace_id)) |> Enum.uniq()

    assert length(traces) == 1

    [app_span] = named(spans, "my_app.handle_message")
    [conversation] = named(spans, "invoke_agent claude-haiku-4-5")

    assert span(conversation, :parent_span_id) == span(app_span, :span_id)
  end

  test "a response that is not a reply is not recorded as one" do
    Application.put_env(:claudex, :trace_content, true)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [], "has_more" => false})
    end)

    assert {:ok, _page} = Claudex.Models.list(client())

    [listing] = named(collect_spans([]), "GET /v1/models")
    recorded = attributes(listing)

    # Every endpoint goes through the same span. A models list with an
    # assistant message whose content is null is a generation that never was.
    refute Map.has_key?(recorded, "gen_ai.completion")
    refute Map.has_key?(recorded, "gen_ai.output.messages")
  end

  defmodule RefusingTool do
    use Claudex.Tool

    @doc "Refuses whatever it is asked."
    @tool true
    @spec divide(integer(), integer()) :: integer()
    def divide(_a, _b), do: raise(Claudex.Tool.Error, "cannot divide by zero")
  end

  test "a tool that fails marks its span, not only an attribute" do
    replies = [
      %{
        message()
        | "content" => [
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "divide",
              "input" => %{"a" => 1, "b" => 0}
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

    assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, RefusingTool))

    [tool] = named(collect_spans([]), "execute_tool divide")

    # A tool returns its failure rather than raising, so without this the span
    # ends green and an error filter passes over it.
    assert {:status, :error, message} = span(tool, :status)
    assert message =~ "cannot divide by zero"
  end

  test "a failed streaming request marks its span" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

    assert {:error, _error} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))

    spans = collect_spans([])
    [request] = named(spans, "chat claude-haiku-4-5")

    # The runner always streams, so without this every failed tool
    # conversation shows green.
    assert {:status, :error, _message} = span(request, :status)

    # And the run it belonged to did not finish, so its own span says so
    # rather than reporting a turn from the middle as the answer.
    [root] = Enum.filter(spans, &(span(&1, :parent_span_id) == :undefined))
    assert {:status, :error, _reason} = span(root, :status)
    refute Map.has_key?(attributes(root), "claudex.stop")
  end

  test "message shaping does not run when content is not being recorded" do
    # Elixir evaluates arguments before the call, so a shaper handed in
    # applied runs whether or not its result is wanted: a conversation walked
    # and rebuilt on every request of every run, for an app that never traces.
    # A tools value that cannot be shaped makes the difference observable.
    body = %{
      model: "claude-haiku-4-5",
      messages: [%{role: "user", content: "hi"}],
      tools: NotAToolModule
    }

    metadata = %{method: :post, path: "/v1/messages", model: "claude-haiku-4-5"}

    assert {_name, attributes} = Attributes.request(metadata, json: body)
    refute Map.has_key?(attributes, "gen_ai.tool.definitions")

    # With content on it is shaped, and this is what shaping it does.
    Application.put_env(:claudex, :trace_content, true)

    assert_raise ArgumentError, ~r/doesn't `use Claudex.Tool`/, fn ->
      Attributes.request(metadata, json: body)
    end
  end

  test "count_tokens is not a generation, though it carries a model" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"input_tokens" => 16}) end)

    assert {:ok, 16} = Messages.count_tokens(client(), Map.delete(@params, :max_tokens))

    [counting] = named(collect_spans([]), "POST /v1/messages/count_tokens")

    # It generates nothing, so counting it as a generation inflates the count
    # and drags the average output tokens towards zero.
    refute Map.has_key?(attributes(counting), "gen_ai.operation.name")
    refute Map.has_key?(attributes(counting), "gen_ai.request.model")
  end

  test "tracing is off when nothing has asked for it" do
    # config/test.exs turns it on for this suite, so the default is only
    # visible with the key gone.
    Application.delete_env(:claudex, :tracing)
    on_exit(fn -> Application.put_env(:claudex, :tracing, true) end)

    refute Tracing.enabled?()
  end

  test "tracing off produces nothing, whatever OpenTelemetry is doing" do
    require OpenTelemetry.Tracer, as: Tracer

    Application.put_env(:claudex, :tracing, false)
    on_exit(fn -> Application.put_env(:claudex, :tracing, true) end)

    stream_reply(message())

    # The SDK is running and exporting: only Claudex's switch is off.
    Tracer.with_span "my_app.work" do
      assert {:ok, _turn} = ToolRunner.run(client(), Map.put(@params, :tools, Calculator))
    end

    spans = collect_spans([])

    assert Enum.map(spans, &span(&1, :name)) == ["my_app.work"]
    assert attributes(hd(spans)) == %{}
    refute Tracing.enabled?()
  end

  defmodule Adder do
    use Claudex.Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b), do: a + b
  end

  test "tracing off leaves a caller's span untouched, on every path" do
    require OpenTelemetry.Tracer, as: Tracer

    Application.put_env(:claudex, :tracing, false)
    on_exit(fn -> Application.put_env(:claudex, :tracing, true) end)

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}})
    end)

    # A non-streaming request and a tool call, neither of which the streaming
    # test reaches. With no span of our own, anything written to "the current
    # span" is written to theirs.
    Tracer.with_span "my_app.work" do
      assert {:error, _error} = Messages.create(client(), @params)
      assert {:ok, 3} = Tool.call(Adder, "add", %{"a" => 1, "b" => 2})
      assert {:ok, 3} = Tool.call(Adder, "add", %{"a" => 1, "b" => 2})
    end

    [app_span] = collect_spans([])

    assert span(app_span, :name) == "my_app.work"
    assert attributes(app_span) == %{}

    # A failed Claudex request must not turn the caller's span red either.
    assert span(app_span, :status) == :undefined
  end

  test "the span hands back what the work returned" do
    assert Tracing.span(fn -> {"work", %{}} end, fn _span -> :the_result end) == :the_result
  end

  test "an exception in the work is recorded on the span and re-raised unchanged" do
    assert_raise RuntimeError, "boom", fn ->
      Tracing.span(fn -> {"work", %{}} end, fn _span -> raise "boom" end)
    end

    assert_receive {:span, recorded}, 2_000

    assert {:status, :error, "boom"} = span(recorded, :status)
    assert {:events, _count, _limit, _type, _dropped, [event]} = span(recorded, :events)

    {:event, _time, :exception, {:attributes, _n, _t, _d, recorded_attributes}} = event

    assert recorded_attributes["exception.type"] == "RuntimeError"
    assert recorded_attributes["exception.message"] == "boom"
  end
end

defmodule Claudex.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, ContentBlock, Error, Message, ToolRunner}
  alias Claudex.Stream.{Event, Handle}
  alias Claudex.TestSupport.{Fixtures, MessageStream}
  alias Claudex.ToolRunner.Turn

  defmodule Calculator do
    use Claudex.Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b), do: a + b

    @doc "Refuses anything negative."
    @tool true
    @spec halve(integer()) :: integer()
    def halve(n) when n < 0, do: raise(Claudex.Tool.Error, "negative numbers are not allowed")
    def halve(n), do: div(n, 2)

    @doc "Stands in for a tool with a bug in it."
    @tool true
    @spec explode() :: integer()
    def explode, do: raise(KeyError, key: :missing, term: %{})

    @doc "Returns structured data."
    @tool true
    @spec lookup(String.t()) :: map()
    def lookup(key), do: %{key => "value"}

    @doc "Returns something JSON can't encode."
    @tool true
    @spec unencodable() :: any()
    def unencodable, do: {:error, :not_found}
  end

  defmodule Revenue do
    use Claudex.Tool

    @doc "Returns the revenue in dollars for a customer id such as C1, C2 or C3."
    @tool true
    @spec revenue(String.t()) :: integer()
    def revenue(id), do: Map.get(%{"C1" => 100, "C2" => 250, "C3" => 75}, id, 0)
  end

  defmodule StallingTransport do
    @moduledoc """
    Serves the first event of a reply and then stalls, the way the API does
    while the model is still writing. A plug stub can't do this: Req collects a
    plug's response before handing it over, so nothing arrives until it returns.
    """

    @first_event """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

    """

    @stall :timer.seconds(5)

    @doc false
    def run(request) do
      {_action, acc} =
        request.into.({:data, @first_event}, {request, Req.Response.new(status: 200)})

      Process.sleep(@stall)

      acc
    end
  end

  defmodule Ledger do
    @moduledoc """
    Reports every time it runs. Under `run/3` a tool runs in the calling
    process, so the report lands in the test's own mailbox.
    """

    use Claudex.Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b) do
      send(self(), {:ran, a, b})

      a + b
    end
  end

  defmodule Tattler do
    @moduledoc """
    Reports that it ran, for a test whose point is that it must not. The
    forwarder propagates `$callers`, so the test process is at the head of it.
    """

    use Claudex.Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b) do
      [caller | _rest] = Process.get(:"$callers")
      send(caller, {:tool_ran, a, b})

      a + b
    end
  end

  defmodule ToolThenStallTransport do
    @moduledoc """
    Emits a complete `tool_use` block, then stalls before `message_delta` and
    `message_stop` — the wire shape when a reply is cut off after Claude has
    finished asking for a tool but before the turn itself has finished.
    """

    @blocks ~S"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"add","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1,\"b\":2}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    """

    @stall :timer.seconds(5)

    @doc false
    def run(request) do
      {_action, acc} =
        request.into.({:data, @blocks}, {request, Req.Response.new(status: 200)})

      Process.sleep(@stall)

      acc
    end
  end

  defmodule SilentTransport do
    @moduledoc """
    Stalls before sending anything at all, so a cancel arrives while the reply
    has not started.
    """

    @stall :timer.seconds(5)

    @doc false
    def run(request) do
      Process.sleep(@stall)

      {request, Req.Response.new(status: 200)}
    end
  end

  @params %{
    model: "claude-haiku-4-5",
    max_tokens: 64,
    tools: Calculator,
    messages: [%{role: "user", content: "What is 12 plus 30?"}]
  }

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp message(content, stop_reason) do
    %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => content,
      "stop_reason" => stop_reason,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp tool_use(name, input, id \\ "toolu_1") do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp text(text), do: %{"type" => "text", "text" => text}

  # Lets the first `allowed` calls run, then halts on every one after.
  defp halt_after(allowed) do
    {:ok, agent} = Agent.start_link(fn -> allowed end)

    fn _call ->
      Agent.get_and_update(agent, fn
        0 -> {{:halt, :awaiting_approval}, 0}
        left -> {:ok, left - 1}
      end)
    end
  end

  defp server_tool_use(name, input) do
    %{"type" => "server_tool_use", "id" => "srvtoolu_1", "name" => name, "input" => input}
  end

  defp respond_with(replies) do
    {:ok, counter} = Agent.start_link(fn -> replies end)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      # The request runs in a process the test never sees, so report home.
      send(test_pid, {:sent, Jason.decode!(raw_body)})

      reply = Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)

      MessageStream.respond(conn, reply)
    end)
  end

  test "run/3 dispatches the tool and returns the final reply with the history" do
    respond_with([
      message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
      message([text("12 plus 30 is 42.")], "end_turn")
    ])

    assert {:ok, %Turn{stop: :completed} = turn} = ToolRunner.run(client(), @params)

    assert Message.text(turn.message) == "12 plus 30 is 42."
    assert length(turn.messages) == 4

    history = turn.messages

    # The history is plain data all the way through: the reply was converted on
    # the way in, so this can be stored and read back without changing shape.
    assert [
             %{role: "user", content: "What is 12 plus 30?"},
             %{role: "assistant", content: [%{type: "tool_use", name: "add"}]},
             %{role: "user", content: [%{type: "tool_result", content: "42", is_error: false}]},
             %{role: "assistant", content: [%{type: "text", text: "12 plus 30 is 42."}]}
           ] = history

    assert {:ok, _json} = Jason.encode(history)
  end

  test "stream/3 yields a turn per reply, carrying the history so far" do
    respond_with([
      message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use"),
      message([text("3")], "end_turn")
    ])

    assert [first, second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert %Turn{index: 1, stop: nil} = first
    assert Turn.tool_use?(first)
    assert [%{content: "3", is_error: false}] = first.tool_results
    assert length(first.messages) == 3

    assert %Turn{index: 2, tool_uses: [], tool_results: [], stop: :completed} = second
    refute Turn.tool_use?(second)
    assert length(second.messages) == 4
  end

  test "stream/3 stops the conversation when the caller halts" do
    respond_with([
      message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use"),
      message([text("3")], "end_turn")
    ])

    turn =
      client()
      |> ToolRunner.stream(@params)
      |> Enum.reduce_while(nil, fn turn, _last -> {:halt, turn} end)

    assert %Turn{index: 1} = turn

    # One request went out; halting stopped the second from ever being sent.
    assert_received {:sent, _first}
    refute_received {:sent, _second}
  end

  defmodule Reader do
    use Claudex.Tool

    @doc "Reads a file and returns its bytes."
    @tool true
    @spec read(String.t()) :: binary()
    def read(_path), do: <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A>>
  end

  test "a tool returning bytes does not break the request that carries them back" do
    respond_with([
      message([tool_use("read", %{"path" => "logo.png"})], "tool_use"),
      message([text("done")], "end_turn")
    ])

    # The result goes into the next request's JSON body. Bytes a file gave
    # back are a binary, so they passed straight through and failed the
    # request rather than the tool, with the tool's own name nowhere in it.
    assert {:ok, %Turn{stop: :completed}} =
             ToolRunner.run(client(), %{@params | tools: Reader})

    assert_received {:sent, _first}
    assert_received {:sent, second}

    assert [_user, _assistant, %{"role" => "user", "content" => [result]}] = second["messages"]
    assert result["content"] =~ "137"
  end

  test "a tool raising Tool.Error becomes an error result Claude can read" do
    respond_with([
      message([tool_use("halve", %{"n" => -4})], "tool_use"),
      message([text("I can't halve a negative number.")], "end_turn")
    ])

    assert [first, _second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert [%{content: "negative numbers are not allowed", is_error: true}] = first.tool_results
  end

  test "an unexpected exception becomes an error result naming its type" do
    respond_with([
      message([tool_use("explode", %{})], "tool_use"),
      message([text("That tool is broken.")], "end_turn")
    ])

    assert [first, _second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert [%{content: content, is_error: true}] = first.tool_results
    assert content =~ "the tool failed:"
    assert content =~ "KeyError"
    assert content =~ "key :missing not found"
  end

  test "a tool_use naming an unknown tool becomes an error result, not a crash" do
    respond_with([
      message([tool_use("nope", %{})], "tool_use"),
      message([text("No such tool.")], "end_turn")
    ])

    assert [first, _second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert [%{content: "no tool named nope", is_error: true}] = first.tool_results
  end

  test "a tool returning something other than a binary is JSON-encoded" do
    respond_with([
      message([tool_use("lookup", %{"key" => "a"})], "tool_use"),
      message([text("done")], "end_turn")
    ])

    assert [first, _second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert [%{content: ~s({"a":"value"})}] = first.tool_results
  end

  test "every result for one reply goes back in a single message" do
    respond_with([
      message(
        [
          tool_use("add", %{"a" => 1, "b" => 2}, "toolu_1"),
          tool_use("add", %{"a" => 3, "b" => 4}, "toolu_2")
        ],
        "tool_use"
      ),
      message([text("3 and 7")], "end_turn")
    ])

    assert {:ok, %Turn{} = turn} = ToolRunner.run(client(), @params)

    assert [_user, _assistant, %{role: "user", content: results}, _final] = turn.messages

    assert [%{tool_use_id: "toolu_1", content: "3"}, %{tool_use_id: "toolu_2", content: "7"}] =
             results
  end

  test "a refusal ends the conversation without running its tool calls" do
    respond_with([message([tool_use("add", %{"a" => 1, "b" => 2})], "refusal")])

    assert [turn] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert turn.stop == :refusal
    assert turn.message.stop_reason == "refusal"
    assert turn.tool_results == []
    assert turn.messages == @params.messages
  end

  test "a stop reason this version doesn't know is reported as such, calls or not" do
    respond_with([message([text("Something new.")], "a_future_reason")])

    assert [turn] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert turn.stop == :unknown
    assert length(turn.messages) == 2
  end

  test "a stop reason this version doesn't know ends the conversation without running its calls" do
    respond_with([
      message([tool_use("add", %{"a" => 1, "b" => 2})], "a_future_reason"),
      message([text("3")], "end_turn")
    ])

    assert [turn] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert turn.stop == :unknown
    assert turn.message.stop_reason == "a_future_reason"
    assert turn.tool_results == []
    assert turn.messages == @params.messages

    assert_received {:sent, _first}
    refute_received {:sent, _second}
  end

  test "max_turns stops a conversation that keeps asking for tools" do
    respond_with(List.duplicate(message([tool_use("add", %{"a" => 1, "b" => 1})], "tool_use"), 3))

    turns = client() |> ToolRunner.stream(@params, max_turns: 3) |> Enum.to_list()

    assert length(turns) == 3
    assert Enum.all?(turns, &Turn.tool_use?/1)

    # The last turn says why it stopped, so "ran out of turns" is not mistaken
    # for "Claude finished", and its tool results are in the history to resume from.
    assert [%Turn{stop: nil}, %Turn{stop: nil}, %Turn{stop: :max_turns} = last] = turns
    assert last.tool_results != []
  end

  test "run/3 returns the error when a request fails" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => "bad params"}
      })
    end)

    assert {:error, %Error{type: :bad_request, message: "bad params"}} =
             ToolRunner.run(client(), @params)
  end

  test "run/3 reports a stream that ends without starting a message" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, conn} =
        conn
        |> Plug.Conn.send_chunked(200)
        |> Plug.Conn.chunk(~s(event: message_stop\ndata: {"type":"message_stop"}\n\n))

      conn
    end)

    assert {:error, %Error{type: :stream}} = ToolRunner.run(client(), @params)
  end

  test "a tool returning something JSON can't encode is described, not fatal" do
    respond_with([
      message([tool_use("unencodable", %{})], "tool_use"),
      message([text("noted")], "end_turn")
    ])

    # PLAN.md's own example of data a tool may legitimately return.
    assert [first, _second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert [%{content: content, is_error: false}] = first.tool_results
    assert content =~ ":not_found"
  end

  describe ":before_call" do
    test "a denial skips the tool and sends the reason back as an error result" do
      test_pid = self()

      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("I could not add those.")], "end_turn")
      ])

      deny = fn %ContentBlock.ToolUse{} = call ->
        send(test_pid, {:asked, call.name, call.input})
        {:deny, "The user declined this tool call."}
      end

      assert [first, last] =
               client() |> ToolRunner.stream(@params, before_call: deny) |> Enum.to_list()

      assert_received {:asked, "add", %{"a" => 12, "b" => 30}}

      assert [%{content: "The user declined this tool call.", is_error: true}] =
               first.tool_results

      assert last.stop == :completed
    end

    test "a halt ends the run, naming the turn's stop" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("unreachable")], "end_turn")
      ])

      halt = fn _call -> {:halt, :awaiting_approval} end

      assert {:ok, turn} = ToolRunner.run(client(), @params, before_call: halt)

      assert turn.stop == :awaiting_approval
      assert [%ContentBlock.ToolUse{name: "add"}] = turn.tool_uses
      assert turn.tool_results == []
      assert List.last(turn.messages).role == "assistant"
    end

    test "a halt keeps the results of the calls that ran before it" do
      respond_with([
        message(
          [tool_use("add", %{"a" => 1, "b" => 2}), tool_use("add", %{"a" => 3, "b" => 4})],
          "tool_use"
        ),
        message([text("unreachable")], "end_turn")
      ])

      {:ok, agent} = Agent.start_link(fn -> :first end)

      halt_second = fn _call ->
        Agent.get_and_update(agent, fn
          :first -> {:ok, :halt}
          :halt -> {{:halt, :awaiting_approval}, :halt}
        end)
      end

      assert {:ok, turn} = ToolRunner.run(client(), @params, before_call: halt_second)

      assert turn.stop == :awaiting_approval
      assert [%{content: "3"}] = turn.tool_results
      assert length(turn.tool_uses) == 2
    end

    test "a halted run resumes from the history and results it left behind" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("42.")], "end_turn")
      ])

      halt = fn _call -> {:halt, :awaiting_approval} end

      assert {:ok, halted} = ToolRunner.run(client(), @params, before_call: halt)
      assert halted.stop == :awaiting_approval

      params = Map.put(@params, :messages, halted.messages)

      assert {:ok, resumed} = ToolRunner.run(client(), params, tool_results: halted.tool_results)

      assert resumed.stop == :completed
      assert Message.text(resumed.message) == "42."

      assert %{role: "user", content: [%{type: "tool_result", content: "42"}]} =
               Enum.at(resumed.messages, 2)
    end

    test "a halted run resumes from a history and results that went through storage" do
      respond_with([
        message(
          [
            tool_use("add", %{"a" => 1, "b" => 2}),
            tool_use("add", %{"a" => 3, "b" => 4}, "toolu_2")
          ],
          "tool_use"
        ),
        message([text("3 and 7.")], "end_turn")
      ])

      assert {:ok, halted} =
               ToolRunner.run(client(), @params, before_call: halt_after(1))

      [stored_messages, stored_results] =
        [halted.messages, halted.tool_results] |> JSON.encode!() |> JSON.decode!()

      params = %{@params | tools: Ledger, messages: stored_messages}

      assert {:ok, resumed} = ToolRunner.run(client(), params, tool_results: stored_results)

      assert resumed.stop == :completed

      assert [
               %{"tool_use_id" => "toolu_1", "content" => "3"},
               %{tool_use_id: "toolu_2", content: "7"}
             ] =
               Enum.at(resumed.messages, 2).content

      assert_received {:ran, 3, 4}
      refute_received {:ran, 1, 2}
    end

    test "a resume runs only the calls that never ran, and asks only about those" do
      test_pid = self()

      respond_with([
        message(
          [
            tool_use("add", %{"a" => 1, "b" => 2}),
            tool_use("add", %{"a" => 3, "b" => 4}, "toolu_2")
          ],
          "tool_use"
        ),
        message([text("3 and 7.")], "end_turn")
      ])

      params = %{@params | tools: Ledger}

      assert {:ok, halted} = ToolRunner.run(client(), params, before_call: halt_after(1))
      assert_received {:ran, 1, 2}

      ask = fn %ContentBlock.ToolUse{} = call ->
        send(test_pid, {:asked, call.id})
        :ok
      end

      assert {:ok, resumed} =
               ToolRunner.run(client(), %{params | messages: halted.messages},
                 tool_results: halted.tool_results,
                 before_call: ask
               )

      assert resumed.stop == :completed
      assert_received {:ran, 3, 4}
      refute_received {:ran, 1, 2}
      assert_received {:asked, "toolu_2"}
      refute_received {:asked, "toolu_1"}
    end

    test "a resume that halts again carries every result so far into the next one" do
      respond_with([
        message(
          [
            tool_use("add", %{"a" => 1, "b" => 2}),
            tool_use("add", %{"a" => 3, "b" => 4}, "toolu_2"),
            tool_use("add", %{"a" => 5, "b" => 6}, "toolu_3")
          ],
          "tool_use"
        ),
        message([text("done")], "end_turn")
      ])

      params = %{@params | tools: Ledger}

      assert {:ok, first} = ToolRunner.run(client(), params, before_call: halt_after(1))

      assert {:ok, second} =
               ToolRunner.run(client(), %{params | messages: first.messages},
                 tool_results: first.tool_results,
                 before_call: halt_after(1)
               )

      assert second.stop == :awaiting_approval
      assert [%{tool_use_id: "toolu_1"}, %{tool_use_id: "toolu_2"}] = second.tool_results

      assert {:ok, third} =
               ToolRunner.run(client(), %{params | messages: second.messages},
                 tool_results: second.tool_results
               )

      assert third.stop == :completed

      for call <- [{1, 2}, {3, 4}, {5, 6}] do
        assert_received {:ran, _a, _b} = ran
        assert ran == Tuple.insert_at(call, 0, :ran)
      end

      refute_received {:ran, _a, _b}
    end

    test "a resumed turn reports zero usage, since it made no request" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("42.")], "end_turn")
      ])

      halt = fn _call -> {:halt, :awaiting_approval} end
      assert {:ok, halted} = ToolRunner.run(client(), @params, before_call: halt)

      turns =
        client()
        |> ToolRunner.stream(%{@params | messages: halted.messages},
          tool_results: halted.tool_results
        )
        |> Enum.to_list()

      assert [%Turn{message: %Message{usage: resumed_usage}}, %Turn{}] = turns
      assert resumed_usage.input_tokens == 0 and resumed_usage.output_tokens == 0
      refute Claudex.Usage.cached?(resumed_usage)

      total =
        Enum.reduce(
          turns,
          0,
          &(&2 + &1.message.usage.input_tokens + &1.message.usage.output_tokens)
        )

      assert total == 15
    end

    test "without :tool_results, a history ending in calls goes to the API as it is, running nothing" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("unreachable")], "end_turn")
      ])

      halt = fn _call -> {:halt, :awaiting_approval} end

      assert {:ok, halted} =
               ToolRunner.run(client(), %{@params | tools: Ledger}, before_call: halt)

      assert_received {:sent, _first}

      ToolRunner.run(client(), %{@params | tools: Ledger, messages: halted.messages})

      assert_received {:sent, %{"messages" => [_question, %{"role" => "assistant"}]}}
      refute_received {:ran, _a, _b}
    end

    test ":tool_results needs a history that ends in tool calls" do
      assert_raise ArgumentError, ~r/:tool_results/, fn ->
        ToolRunner.run(client(), @params, tool_results: [])
      end
    end

    test ":tool_results refuses a result for a call the reply did not make" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("unreachable")], "end_turn")
      ])

      halt = fn _call -> {:halt, :awaiting_approval} end
      assert {:ok, halted} = ToolRunner.run(client(), @params, before_call: halt)

      assert_raise ArgumentError, ~r/toolu_other/, fn ->
        ToolRunner.run(client(), %{@params | messages: halted.messages},
          tool_results: [Claudex.Tool.result("toolu_other", "1")]
        )
      end
    end

    test "a halt must name a stop of its own" do
      for stop <- [nil, :completed, :truncated, :refusal, :unknown, :max_turns] do
        respond_with([message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use")])

        assert_raise ArgumentError, ~r/:halt/, fn ->
          ToolRunner.run(client(), @params, before_call: fn _call -> {:halt, stop} end)
        end
      end
    end

    test "returning :ok runs the tool as usual" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("42.")], "end_turn")
      ])

      allow = fn %ContentBlock.ToolUse{} -> :ok end

      assert [first, _last] =
               client() |> ToolRunner.stream(@params, before_call: allow) |> Enum.to_list()

      assert [%{content: "42", is_error: false}] = first.tool_results
    end

    test "each call is offered separately" do
      test_pid = self()

      respond_with([
        message(
          [
            tool_use("add", %{"a" => 1, "b" => 2}, "toolu_1"),
            tool_use("add", %{"a" => 3, "b" => 4}, "toolu_2")
          ],
          "tool_use"
        ),
        message([text("done")], "end_turn")
      ])

      gate = fn %ContentBlock.ToolUse{id: id} ->
        send(test_pid, {:asked, id})
        if id == "toolu_1", do: :ok, else: {:deny, "only the first"}
      end

      assert [first, _last] =
               client() |> ToolRunner.stream(@params, before_call: gate) |> Enum.to_list()

      assert_received {:asked, "toolu_1"}
      assert_received {:asked, "toolu_2"}

      assert [%{content: "3", is_error: false}, %{content: "only the first", is_error: true}] =
               first.tool_results
    end

    test "an unexpected return value is a programmer error" do
      respond_with([message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use")])

      assert_raise ArgumentError,
                   ~r/:before_call must return :ok, \{:deny, reason\} or \{:halt, stop\}/,
                   fn ->
                     client()
                     |> ToolRunner.stream(@params, before_call: fn _call -> :maybe end)
                     |> Enum.to_list()
                   end
    end
  end

  describe ":on_event" do
    test "every turn reports its events to the callback, in the process driving the loop" do
      test_pid = self()

      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("42.")], "end_turn")
      ])

      watch = fn event -> send(test_pid, {:event, self(), event}) end

      assert {:ok, %Turn{stop: :completed}} = ToolRunner.run(client(), @params, on_event: watch)

      # The arguments of the first turn's tool call, and the text of the second:
      # both turns stream, not just the last one.
      assert_received {:event, ^test_pid, %Event.ContentBlockDelta{delta: {:input_json, _}}}
      assert_received {:event, ^test_pid, %Event.ContentBlockDelta{delta: {:text, "42."}}}
      assert_received {:event, ^test_pid, %Event.MessageStop{}}
    end

    test "the deltas spell out the reply the turn carries" do
      respond_with([message([text("12 plus 30 is 42.")], "end_turn")])

      {:ok, chunks} = Agent.start_link(fn -> [] end)

      watch = fn
        %Event.ContentBlockDelta{delta: {:text, chunk}} ->
          Agent.update(chunks, &[chunk | &1])

        _event ->
          :ok
      end

      assert {:ok, turn} = ToolRunner.run(client(), @params, on_event: watch)

      assert chunks |> Agent.get(&Enum.reverse/1) |> Enum.join() == Message.text(turn.message)
    end
  end

  describe "a paused turn" do
    test "resumes on the history as it stands, adding nothing to it" do
      respond_with([
        message([server_tool_use("web_search", %{"query" => "kyiv weather"})], "pause_turn"),
        message([text("It is 18°C in Kyiv.")], "end_turn")
      ])

      assert [first, second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

      assert first.stop == nil
      assert first.message.stop_reason == "pause_turn"
      assert first.tool_results == []
      assert second.stop == :completed

      assert_received {:sent, _first}
      assert_received {:sent, %{"messages" => messages}}

      # The paused reply goes back as it came, with no message of ours between
      # it and the request that resumes it.
      assert [%{"role" => "user"}, %{"role" => "assistant"}] = messages
    end

    test "still stops at the turn limit if the pauses keep coming" do
      paused = message([server_tool_use("web_search", %{"query" => "kyiv"})], "pause_turn")

      respond_with(List.duplicate(paused, 2))

      turns = client() |> ToolRunner.stream(@params, max_turns: 2) |> Enum.to_list()

      assert [%Turn{stop: nil}, %Turn{stop: :max_turns}] = turns
    end
  end

  test "a paused turn resumes carrying the server tool's arguments" do
    # The search the API is part-way through is what makes the paused reply
    # resumable; a history that replays it with an empty input starts it again.
    search = %{
      "type" => "server_tool_use",
      "id" => "srvtoolu_1",
      "name" => "web_search",
      "input" => %{"query" => "kyiv population"}
    }

    respond_with([
      message([search], "pause_turn"),
      message([text("Around 3 million.")], "end_turn")
    ])

    assert [_first, second] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

    assert second.stop == :completed

    assert_received {:sent, _first}
    assert_received {:sent, %{"messages" => [_user, %{"content" => [replayed]}]}}

    assert replayed["input"] == %{"query" => "kyiv population"}
  end

  test "runs a tool call that arrives whole in message_start" do
    {:ok, replies} =
      Agent.start_link(fn ->
        [
          &Plug.Conn.send_resp(&1, 200, Fixtures.sse!("programmatic_tool_call_stream")),
          &MessageStream.respond(&1, message([text("The total is 425.")], "end_turn"))
        ]
      end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.get_and_update(replies, fn [reply | rest] -> {reply, rest} end).(conn)
    end)

    params = %{@params | tools: Revenue}

    assert [first, second] = client() |> ToolRunner.stream(params) |> Enum.to_list()

    assert [%ContentBlock.ToolUse{name: "revenue"}] = first.tool_uses
    assert [%{content: "250", is_error: false}] = first.tool_results
    assert second.stop == :completed
  end

  test "the next request runs in the container the reply named" do
    respond_with([
      Map.put(message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use"), "container", %{
        "id" => "container_1",
        "expires_at" => "2026-10-10T12:00:00Z"
      }),
      message([text("3")], "end_turn")
    ])

    assert {:ok, %Turn{stop: :completed}} = ToolRunner.run(client(), @params)

    assert_received {:sent, first}
    refute Map.has_key?(first, "container")
    assert_received {:sent, %{"container" => "container_1"}}
  end

  test "a container given with skills and no id gains the reply's id and keeps its skills" do
    skills = [%{type: "anthropic", skill_id: "xlsx", version: "latest"}]

    respond_with([
      Map.put(message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use"), "container", %{
        "id" => "container_1"
      }),
      message([text("3")], "end_turn")
    ])

    params = Map.put(@params, :container, %{skills: skills})

    assert {:ok, _turn} = ToolRunner.run(client(), params)

    assert_received {:sent, %{"container" => %{"skills" => [_skill]} = first}}
    refute Map.has_key?(first, "id")
    assert_received {:sent, %{"container" => %{"id" => "container_1", "skills" => [_skill]}}}
  end

  test "a toolset call goes back with its toolset_name, and so does its result" do
    respond_with([Fixtures.json!("toolset_tool_use"), message([text("Done.")], "end_turn")])

    assert {:ok, _turn} = ToolRunner.run(client(), @params)

    assert_received {:sent, _first}

    assert_received {:sent,
                     %{"messages" => [_user, %{"content" => [call]}, %{"content" => [result]}]}}

    assert %{"toolset_name" => "computer", "caller" => %{"type" => "direct"}} = call
    assert %{"tool_use_id" => id, "toolset_name" => "computer"} = result
    assert id == call["id"]
  end

  describe "a reply that ran out of room" do
    test "stops the loop rather than reading as finished" do
      respond_with([message([text("The answer is")], "max_tokens")])

      assert [turn] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

      assert turn.stop == :truncated
      assert turn.message.stop_reason == "max_tokens"
    end

    test "the model's own context window counts too" do
      respond_with([message([text("...")], "model_context_window_exceeded")])

      assert [%Turn{stop: :truncated}] = client() |> ToolRunner.stream(@params) |> Enum.to_list()
    end

    test "leaves the tool calls it was part-way through asking for unrun" do
      respond_with([message([tool_use("add", %{"a" => 12, "b" => 30})], "max_tokens")])

      assert [turn] = client() |> ToolRunner.stream(@params) |> Enum.to_list()

      assert turn.stop == :truncated
      assert turn.tool_results == []

      # One request went out: the loop never sent results for a half-asked call.
      assert_received {:sent, _first}
      refute_received {:sent, _second}
    end

    test "leaves its calls unrun when its stored history is passed back" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "max_tokens"),
        message([text("42.")], "end_turn")
      ])

      assert {:ok, %Turn{stop: :truncated} = truncated} = ToolRunner.run(client(), @params)
      assert_received {:sent, _first}

      stored = truncated.messages |> JSON.encode!() |> JSON.decode!()

      assert {:ok, %Turn{stop: :completed}} =
               ToolRunner.run(client(), Map.put(@params, :messages, stored))

      refute_received {:sent,
                       %{"messages" => [_, _, %{"content" => [%{"type" => "tool_result"}]}]}}
    end
  end

  test "a cancel ref stops stream/3, and the turn it interrupts is truncated" do
    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 0,
        req_options: [adapter: ToolThenStallTransport]
      )

    cancel_ref = make_ref()
    parent = self()

    pid =
      spawn_link(fn ->
        # The forwarder does this for stream_to/3; a bare stream/3 in a task
        # of your own carries whatever its caller set up.
        Process.put(:"$callers", [parent])

        turns =
          client
          |> ToolRunner.stream(%{@params | tools: Tattler},
            cancel_ref: cancel_ref,
            on_event: &signal_block_stop(parent, &1)
          )
          |> Enum.to_list()

        send(parent, {:turns, turns})
      end)

    # Cancel once the tool_use block is whole, so the reply really does carry
    # a call the loop could have dispatched.
    assert_receive :block_stopped, 2_000
    send(pid, {:claudex_cancel, cancel_ref})

    assert_receive {:turns, [%Turn{stop: :truncated} = turn]}, 2_000

    assert [%ContentBlock.ToolUse{name: "add"}] = turn.tool_uses
    assert turn.tool_results == []
    refute_received {:tool_ran, _a, _b}
  end

  defp signal_block_stop(parent, %Event.ContentBlockStop{}), do: send(parent, :block_stopped)
  defp signal_block_stop(_parent, _event), do: :ok

  describe "stream_to/3" do
    test "sends each event as it arrives, each turn as it completes, then :done" do
      respond_with([
        message([tool_use("add", %{"a" => 12, "b" => 30})], "tool_use"),
        message([text("42")], "end_turn")
      ])

      assert {:ok, %Handle{ref: ref, pid: pid}} = ToolRunner.stream_to(client(), @params)
      assert is_pid(pid)

      assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 2_000

      assert_receive {:claudex, ^ref, {:turn, %Turn{index: 1} = first}}, 2_000
      assert [%ContentBlock.ToolUse{name: "add"}] = first.tool_uses
      assert [%{content: "42", is_error: false}] = first.tool_results

      assert_receive {:claudex, ^ref, {:turn, %Turn{index: 2, stop: :completed} = second}}, 2_000
      assert Message.text(second.message) == "42"

      assert_receive {:claudex, ^ref, :done}, 2_000
    end

    test "delivers to another process when told to" do
      respond_with([message([text("42")], "end_turn")])

      parent = self()
      target = start_supervised!({Task, fn -> relay(parent) end}, restart: :temporary)

      assert {:ok, %Handle{ref: ref}} = ToolRunner.stream_to(client(), @params, to: target)

      # Everything arrives by way of the target, so nothing proves the routing
      # except the target having seen it.
      assert_receive {:relayed, {:claudex, ^ref, {:turn, %Turn{}}}}, 2_000
      assert_receive {:relayed, {:claudex, ^ref, :done}}, 2_000

      refute_received {:claudex, ^ref, _direct}
    end

    test "carries on when the process it delivers to is gone" do
      respond_with([
        message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use"),
        message([text("3")], "end_turn")
      ])

      assert {:ok, %Handle{pid: pid}} = ToolRunner.stream_to(client(), @params, to: dead_pid())

      assert_exits_normally(pid)

      # Only the caller is linked, so a destination that has gone away does not
      # end the conversation: both requests went out, and the caller decides
      # what a missing reader means.
      assert_received {:sent, _first}
      assert_received {:sent, _second}
    end

    test "monitor: true stops the conversation when that process is gone" do
      respond_with([
        message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use"),
        message([text("3")], "end_turn")
      ])

      dead = dead_pid()

      assert {:ok, %Handle{pid: pid}} =
               ToolRunner.stream_to(client(), @params, to: dead, monitor: true)

      assert_exits_normally(pid)

      # The turn already in flight was paid for; the next one never went out.
      assert_received {:sent, _first}
      refute_received {:sent, _second}
    end

    test "monitor: true delivers as usual while that process is alive" do
      respond_with([
        message([tool_use("add", %{"a" => 1, "b" => 2})], "tool_use"),
        message([text("3")], "end_turn")
      ])

      assert {:ok, %Handle{ref: ref}} =
               ToolRunner.stream_to(client(), @params, to: self(), monitor: true)

      # Watching the destination changes nothing while it is there.
      assert_receive {:claudex, ^ref, {:turn, %Turn{index: 1}}}, 2_000
      assert_receive {:claudex, ^ref, {:turn, %Turn{index: 2, stop: :completed}}}, 2_000
      assert_receive {:claudex, ^ref, :done}, 2_000
    end

    test "runs an :on_event of the caller's own as well as forwarding it" do
      respond_with([message([text("42")], "end_turn")])

      parent = self()

      assert {:ok, %Handle{ref: ref}} =
               ToolRunner.stream_to(client(), @params, on_event: &send(parent, {:mine, &1}))

      assert_receive {:mine, %Event.MessageStart{}}, 2_000
      assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 2_000
      assert_receive {:claudex, ^ref, :done}, 2_000
    end

    test "sends a failed request as an error rather than raising it at the caller" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

      assert {:ok, %Handle{ref: ref}} = ToolRunner.stream_to(client(), @params)

      assert_receive {:claudex, ^ref, {:error, %Error{type: :rate_limit}}}, 2_000
      refute_receive {:claudex, ^ref, :done}, 200

      # The forwarder is linked, so a raise that escaped it would have taken
      # this process with it before the assertion above ran.
      assert Process.alive?(self())
    end

    test "sends a missing required parameter as an error too" do
      assert {:ok, %Handle{ref: ref}} =
               ToolRunner.stream_to(client(), Map.delete(@params, :max_tokens))

      assert_receive {:claudex, ^ref, {:error, %Error{type: :bad_request} = error}}, 2_000
      assert error.message =~ "max_tokens"
    end

    test "cancel/1 stops the request in flight, without waiting for the reply" do
      assert {:ok, %Handle{ref: ref} = handle} = ToolRunner.stream_to(stalling_client(), @params)

      assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 2_000

      assert Claudex.Stream.cancel(handle) == :ok

      # The stub is five seconds into a stall. A cancel the loop only notices
      # between turns cannot report inside this window.
      assert_receive {:claudex, ^ref, :cancelled}, 1_000

      refute_receive {:claudex, ^ref, {:turn, _turn}}, 200
      refute_receive {:claudex, ^ref, :done}, 100
    end

    test "a cancel landing before the reply starts reports as cancelled, not as an error" do
      client =
        Client.new(
          api_key: "sk-ant-test",
          max_retries: 0,
          req_options: [adapter: SilentTransport]
        )

      assert {:ok, %Handle{ref: ref} = handle} = ToolRunner.stream_to(client, @params)

      assert Claudex.Stream.cancel(handle) == :ok

      # Nothing accumulated, so the turn ends by raising rather than by running
      # out. That is the cancel arriving, and it must not read as a failure.
      assert_receive {:claudex, ^ref, :cancelled}, 1_000

      refute_receive {:claudex, ^ref, {:error, _error}}, 200
    end

    test "a cancelled reply does not run the tool calls it was part-way through asking for" do
      client =
        Client.new(
          api_key: "sk-ant-test",
          max_retries: 0,
          req_options: [adapter: ToolThenStallTransport]
        )

      assert {:ok, %Handle{ref: ref} = handle} =
               ToolRunner.stream_to(client, %{@params | tools: Tattler})

      # The block is complete, so the reply really does carry a tool_use. What
      # it never gets is a stop reason, because message_delta never arrives.
      assert_receive {:claudex, ^ref, {:event, %Event.ContentBlockStop{}}}, 2_000

      assert Claudex.Stream.cancel(handle) == :ok
      assert_receive {:claudex, ^ref, :cancelled}, 2_000

      refute_receive {:tool_ran, _a, _b}, 500
      refute_received {:claudex, ^ref, {:turn, _turn}}
    end

    defp dead_pid do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      pid
    end

    defp assert_exits_normally(pid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    defp relay(parent) do
      receive do
        message ->
          send(parent, {:relayed, message})
          relay(parent)
      end
    end

    defp stalling_client do
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 0,
        req_options: [adapter: StallingTransport]
      )
    end
  end
end

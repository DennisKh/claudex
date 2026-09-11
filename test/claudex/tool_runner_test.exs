defmodule Claudex.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, ContentBlock, Error, Message, ToolRunner}
  alias Claudex.Stream.Event
  alias Claudex.TestSupport.MessageStream
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
    assert length(turn.messages) == 2
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

      assert_raise ArgumentError, ~r/:before_call must return :ok or \{:deny, reason\}/, fn ->
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
  end
end

defmodule Claudex.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, ContentBlock, Error, Message, ToolRunner}
  alias Claudex.Stream.{Event, Handle}
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

defmodule Claudex.Live.ToolRunnerTest do
  @moduledoc """
  End-to-end coverage of `Claudex.ToolRunner` — the agentic loop running
  against the real API, tools and all.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Message, ToolRunner}
  alias Claudex.ToolRunner.Turn

  # The system prompt goes in the top-level `:system` param, not as a message.
  # A `role: "system"` entry in `messages` is a different feature — a
  # mid-conversation directive — and the API rejects it at position 0 whatever
  # the model, telling you to use this parameter instead.
  @system "You are a calculator. Use the provided tools for every calculation, " <>
            "and answer with the number alone."

  defmodule Calculator do
    @moduledoc false
    use Claudex.Tool

    @doc "Adds two integers together."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b) when a > 100 or b > 100 do
      raise Claudex.Tool.Error, "values above 100 need approval before I can add them"
    end

    def add(a, b), do: a + b

    @doc "Subtracts the second integer from the first."
    @tool true
    @spec subtract(integer(), integer()) :: integer()
    def subtract(a, b), do: a - b
  end

  defmodule Workspace do
    @moduledoc false
    use Claudex.Tool

    @doc "Deletes a file from the workspace. Destructive and irreversible."
    @tool %{args: [path: "Path of the file to delete, relative to the workspace root."]}
    @spec delete_file(String.t()) :: String.t()
    def delete_file(path) do
      # Tools run in the process enumerating the stream, so a marker here is
      # visible to the test. Whether it was set is the proof that the tool
      # either ran or didn't.
      Process.put(:deleted, path)

      "deleted #{path}"
    end
  end

  defp params(messages, extra \\ %{}) do
    Map.merge(
      %{
        model: @model,
        max_tokens: 512,
        system: @system,
        tools: Calculator,
        messages: messages
      },
      extra
    )
  end

  test "takes a system prompt and several messages in one turn", %{client: client} do
    messages = [
      Message.user("I have two numbers: 12 and 30."),
      Message.assistant("Got it. What would you like me to do with them?"),
      Message.user("Add them.")
    ]

    assert {:ok, %Turn{stop: :completed} = turn} = ToolRunner.run(client, params(messages))

    history = turn.messages
    assert Message.text(turn.message) =~ "42"

    # The three we sent, plus the tool call, its result, and the final answer.
    assert length(history) == 6
    assert Enum.map(history, & &1.role) == ~w(user assistant user assistant user assistant)

    # It really used the tool rather than doing the arithmetic itself.
    assert Enum.any?(history, fn message ->
             is_list(message.content) and
               Enum.any?(message.content, &match?(%{type: "tool_use", name: "add"}, &1))
           end)
  end

  test "continues a conversation from the history it returned", %{client: client} do
    {:ok, %Turn{messages: history}} =
      ToolRunner.run(client, params([Message.user("What is 12 plus 30?")]))

    follow_up = Message.append(history, Message.user("Now subtract 8 from that."))

    assert {:ok, %Turn{stop: :completed} = turn} = ToolRunner.run(client, params(follow_up))

    history = turn.messages
    assert Message.text(turn.message) =~ "34"
    assert length(history) > length(follow_up)

    # Nothing in that second question says 42; it came from the history.
    assert Enum.any?(history, fn message ->
             is_list(message.content) and
               Enum.any?(
                 message.content,
                 &match?(%{type: "tool_use", name: "subtract", input: %{"a" => 42}}, &1)
               )
           end)
  end

  test "a tool that refuses sends its reason back and the conversation goes on", %{client: client} do
    # The refusal is a rule Claude can't see coming — it has no reason not to
    # call add/2 here, so the tool is what turns the request down.
    turns =
      client
      |> ToolRunner.stream(params([Message.user("What is 150 plus 30?")]))
      |> Enum.to_list()

    refusal =
      Enum.find_value(turns, fn turn ->
        Enum.find(turn.tool_results, & &1.is_error)
      end)

    assert refusal, "expected add/2 to refuse, got: #{inspect(turns)}"
    assert refusal.content =~ "need approval"

    # It kept going and answered rather than dying on the refusal.
    assert %Turn{} = last = List.last(turns)
    assert last.tool_uses == []
    assert Message.text(last.message) != ""
  end

  describe ":before_call against the real API" do
    @approval_system "You manage a file workspace. Use the provided tool when asked to " <>
                       "delete a file. Report plainly what happened."

    defp approval_params(prompt) do
      %{
        model: @model,
        max_tokens: 512,
        system: @approval_system,
        tools: Workspace,
        messages: [Message.user(prompt)]
      }
    end

    test "an approved call runs the tool", %{client: client} do
      assert [first | _rest] =
               client
               |> ToolRunner.stream(approval_params("Delete report.csv please."),
                 before_call: fn %ContentBlock.ToolUse{name: "delete_file"} -> :ok end
               )
               |> Enum.to_list()

      assert [%{is_error: false, content: content}] = first.tool_results
      assert content =~ "deleted"

      # The side effect really happened, on the file that was asked for.
      assert Process.get(:deleted) =~ "report.csv"
    end

    test "a denied call never reaches the tool, and Claude carries on", %{client: client} do
      test_pid = self()

      turns =
        client
        |> ToolRunner.stream(approval_params("Delete report.csv please."),
          before_call: fn %ContentBlock.ToolUse{} = call ->
            send(test_pid, {:asked, call.name, call.input})

            {:deny, "The user did not approve this deletion."}
          end
        )
        |> Enum.to_list()

      assert_received {:asked, "delete_file", %{"path" => path}}
      assert path =~ "report.csv"

      assert [first | _rest] = turns

      assert [%{is_error: true, content: "The user did not approve this deletion."}] =
               first.tool_results

      # The one that matters: the tool never ran, so nothing it would have done
      # happened. The approval test above proves this marker is observable.
      refute Process.get(:deleted)

      # The denial reached Claude as a result it could reason about rather than
      # ending the conversation.
      assert %Turn{stop: :completed} = List.last(turns)
    end
  end
end

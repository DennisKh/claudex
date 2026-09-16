defmodule Claudex.Tracing.MessagesTest do
  @moduledoc """
  The shapes, one function at a time. Everything here is reached through a
  span elsewhere, which tests the happy path and nothing either side of it:
  a block type the conventions have no part for, a body that is not a reply,
  a `:tools` value that is still a module.
  """

  use ExUnit.Case, async: true

  alias Claudex.Tracing.Messages

  defmodule Calculator do
    @moduledoc false
    use Claudex.Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b), do: a + b
  end

  describe "input/1" do
    test "a string message becomes one text part" do
      assert [%{role: "user", parts: [%{type: "text", content: "hi"}]}] =
               Messages.input([%{role: "user", content: "hi"}])
    end

    test "a tool_use block becomes a tool_call part, carrying its id" do
      blocks = [%{type: "tool_use", id: "toolu_1", name: "add", input: %{"a" => 1}}]

      assert [%{role: "assistant", parts: [part]}] =
               Messages.input([%{role: "assistant", content: blocks}])

      assert part == %{type: "tool_call", id: "toolu_1", name: "add", arguments: %{"a" => 1}}
    end

    test "a tool_result block becomes a tool_call_response part" do
      blocks = [%{type: "tool_result", tool_use_id: "toolu_1", content: "42"}]

      assert [%{parts: [part]}] = Messages.input([%{role: "user", content: blocks}])
      assert part == %{type: "tool_call_response", id: "toolu_1", response: "42"}
    end

    test "string keys are read the same as atom keys" do
      blocks = [%{"type" => "tool_use", "id" => "t1", "name" => "add", "input" => %{}}]

      assert [%{role: "assistant", parts: [%{type: "tool_call", id: "t1"}]}] =
               Messages.input([%{"role" => "assistant", "content" => blocks}])
    end

    test "a block type the conventions have no part for keeps its own name" do
      # Thinking, server tools, images. Dropping them would make a trace of a
      # thinking reply look like a reply that said nothing.
      blocks = [%{type: "thinking", thinking: "hmm", signature: "sig"}]

      assert [%{parts: [%{type: "thinking", content: block}]}] =
               Messages.input([%{role: "assistant", content: blocks}])

      assert block.thinking == "hmm"
    end

    test "anything that is not a list of messages is no messages" do
      assert Messages.input(nil) == []
      assert Messages.input("not a list") == []
    end
  end

  describe "output/1" do
    test "wraps content in a single assistant message" do
      assert [%{role: "assistant", parts: [%{type: "text", content: "42"}]}] =
               Messages.output([%{type: "text", text: "42"}])
    end

    test "nil is nothing, not an assistant message with nothing in it" do
      # Every endpoint shares one span. A models list must not arrive as a
      # generation whose assistant said null.
      assert Messages.output(nil) == nil
    end
  end

  describe "system/1" do
    test "a string becomes one text instruction" do
      assert Messages.system("be brief") == [%{type: "text", content: "be brief"}]
    end

    test "the block form the API also accepts is read too" do
      blocks = [%{type: "text", text: "one"}, %{"type" => "text", "text" => "two"}]

      assert Messages.system(blocks) == [
               %{type: "text", content: "one"},
               %{type: "text", content: "two"}
             ]
    end

    test "no system prompt is nil, not an empty instruction" do
      assert Messages.system(nil) == nil
    end
  end

  describe "definitions/1" do
    test "expands a tool module, because params carry one and a body does not" do
      assert [%{type: "function", name: "add", description: description, parameters: schema}] =
               Messages.definitions(Calculator)

      assert description =~ "Adds two integers"
      assert schema.type == "object"
    end

    test "takes already-expanded tool maps" do
      tools = [%{name: "add", description: "d", input_schema: %{type: "object"}}]

      assert [%{type: "function", name: "add", parameters: %{type: "object"}}] =
               Messages.definitions(tools)
    end

    test "no tools is nil rather than an empty list" do
      assert Messages.definitions(nil) == nil
      assert Messages.definitions([]) == nil
    end
  end

  describe "chat_input/2" do
    test "puts the system prompt at the front, where a reader of it expects one" do
      messages = [%{role: "user", content: "hi"}]

      assert [%{role: "system", content: "be brief"}, %{role: "user", content: "hi"}] =
               Messages.chat_input(messages, "be brief")
    end

    test "several system blocks arrive as one system message" do
      blocks = [%{type: "text", text: "one"}, %{type: "text", text: "two"}]

      assert [%{role: "system", content: content} | _rest] = Messages.chat_input([], blocks)
      assert content == "one\ntwo"
    end

    test "without a system prompt the messages are unchanged" do
      messages = [%{role: "user", content: "hi"}]

      assert Messages.chat_input(messages, nil) == messages
    end
  end

  describe "chat_output/1" do
    test "a reply asking for a tool says so under tool_calls" do
      blocks = [%{type: "tool_use", id: "t1", name: "add", input: %{"a" => 1}}]

      assert %{role: "assistant", content: "", tool_calls: [call]} = Messages.chat_output(blocks)
      assert call == %{type: "tool_call", id: "t1", name: "add", args: %{"a" => 1}}
    end

    test "text blocks join into the content" do
      blocks = [%{type: "text", text: "4"}, %{type: "text", text: "2"}]

      assert %{content: "42", tool_calls: []} = Messages.chat_output(blocks)
    end

    test "a reply with both carries both" do
      blocks = [
        %{type: "text", text: "let me check"},
        %{type: "tool_use", id: "t1", name: "add", input: %{}}
      ]

      assert %{content: "let me check", tool_calls: [%{name: "add"}]} =
               Messages.chat_output(blocks)
    end

    test "nil is nothing here too" do
      assert Messages.chat_output(nil) == nil
    end
  end
end

defmodule Claudex.MessageTest do
  use ExUnit.Case, async: true

  alias Claudex.{ContentBlock, Message}

  doctest Claudex.Message

  @response %{
    "id" => "msg_123",
    "type" => "message",
    "role" => "assistant",
    "model" => "claude-opus-5",
    "content" => [
      %{"type" => "text", "text" => "Hello, "},
      %{"type" => "text", "text" => "world."}
    ],
    "stop_reason" => "end_turn",
    "stop_sequence" => nil,
    "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
  }

  test "decode/1 builds a Message with typed content blocks and usage" do
    message = Message.decode(@response)

    assert message.id == "msg_123"
    assert message.model == "claude-opus-5"
    assert message.stop_reason == "end_turn"
    assert [%Claudex.ContentBlock.Text{}, %Claudex.ContentBlock.Text{}] = message.content

    assert %Claudex.Usage{input_tokens: 10, output_tokens: 5} = message.usage
    assert message.usage.cache_read_input_tokens == nil

    # Whatever the API sent is kept, so a counter Claudex doesn't model yet is
    # still reachable.
    assert message.usage.raw == @response["usage"]
    assert message.raw == @response
  end

  test "text/1 joins every text block" do
    message = Message.decode(@response)

    assert Message.text(message) == "Hello, world."
  end

  test "text/1 skips non-text blocks" do
    response = %{
      @response
      | "content" => [
          %{"type" => "text", "text" => "answer: "},
          %{"type" => "tool_use", "id" => "t1", "name" => "calc", "input" => %{}}
        ]
    }

    message = Message.decode(response)

    assert Message.text(message) == "answer: "
  end

  describe "building messages" do
    test "user/1 and assistant/1 wrap text in the right role" do
      assert Message.user("hello") == %{role: "user", content: "hello"}
      assert Message.assistant("hi there") == %{role: "assistant", content: "hi there"}
    end

    test "user/1 takes content blocks as well as text" do
      blocks = [%{type: "text", text: "what is this?"}, %{type: "image", source: %{}}]

      assert Message.user(blocks) == %{role: "user", content: blocks}
    end

    test "tool_results/1 sends results back as a user message" do
      results = [Claudex.Tool.result("toolu_1", "42")]

      assert Message.tool_results(results) == %{role: "user", content: results}
    end
  end

  describe "to_param/1" do
    test "converts a decoded message into request params" do
      message = %Message{
        role: "assistant",
        content: [
          %ContentBlock.Text{text: "here you go"},
          %ContentBlock.ToolUse{id: "toolu_1", name: "add", input: %{"a" => 1}}
        ]
      }

      assert Message.to_param(message) == %{
               role: "assistant",
               content: [
                 %{type: "text", text: "here you go"},
                 %{type: "tool_use", id: "toolu_1", name: "add", input: %{"a" => 1}}
               ]
             }
    end

    test "converts content blocks inside a message you built yourself" do
      built = Message.user([%ContentBlock.Text{text: "hi"}])

      assert Message.to_param(built) == %{role: "user", content: [%{type: "text", text: "hi"}]}
    end

    test "leaves a plain message untouched" do
      built = Message.user("hi")

      assert Message.to_param(built) == built
    end

    test "round-trips a block type Claudex does not model" do
      raw = %{"type" => "mcp_tool_use", "id" => "mcptoolu_1", "name" => "search_docs"}
      message = %Message{role: "assistant", content: [ContentBlock.decode(raw)]}

      assert Message.to_param(message) == %{role: "assistant", content: [raw]}
    end

    test "keeps a thinking block whole, signature included" do
      message = %Message{
        role: "assistant",
        content: [%ContentBlock.Thinking{thinking: "hmm", signature: "sig"}]
      }

      assert Message.to_param(message) == %{
               role: "assistant",
               content: [%{type: "thinking", thinking: "hmm", signature: "sig"}]
             }
    end
  end

  describe "append/2" do
    test "adds a message and converts it to plain data" do
      reply = %Message{role: "assistant", content: [%ContentBlock.Text{text: "hi"}]}

      history =
        []
        |> Message.append(Message.user("hello"))
        |> Message.append(reply)

      assert history == [
               %{role: "user", content: "hello"},
               %{role: "assistant", content: [%{type: "text", text: "hi"}]}
             ]
    end

    test "adds several messages at once, in order" do
      history = Message.append([], [Message.user("one"), Message.assistant("two")])

      assert [%{content: "one"}, %{content: "two"}] = history
    end

    test "produces a history that survives a round trip through JSON" do
      reply = %Message{
        role: "assistant",
        content: [%ContentBlock.ToolUse{id: "toolu_1", name: "add", input: %{"a" => 1}}]
      }

      history = Message.append([Message.user("go")], reply)

      assert {:ok, json} = Jason.encode(history)
      assert {:ok, decoded} = Jason.decode(json)

      assert [
               %{"role" => "user", "content" => "go"},
               %{"role" => "assistant", "content" => [%{"type" => "tool_use", "name" => "add"}]}
             ] = decoded
    end
  end

  test "to_param/1 keeps citations, which are part of the block" do
    block = %ContentBlock.Text{text: "cited", citations: [%{"type" => "page_location"}]}
    message = %Message{role: "assistant", content: [block]}

    assert Message.to_param(message) == %{
             role: "assistant",
             content: [
               %{type: "text", text: "cited", citations: [%{"type" => "page_location"}]}
             ]
           }
  end

  test "to_param/1 leaves a foreign struct alone rather than mangling it" do
    assert Message.to_param(%URI{path: "/x"}) == %URI{path: "/x"}
  end

  describe "stop/1" do
    test "answers for every reason the API documents" do
      mapping = %{
        "end_turn" => :completed,
        "stop_sequence" => :completed,
        "tool_use" => :tool_use,
        "pause_turn" => :paused,
        "max_tokens" => :truncated,
        "model_context_window_exceeded" => :truncated,
        "refusal" => :refusal
      }

      for {reason, stop} <- mapping do
        assert Message.stop(reason) == stop
        assert Message.stop(%Message{stop_reason: reason}) == stop
      end
    end

    test "a reason it doesn't model, or none at all, is :unknown" do
      assert Message.stop(nil) == :unknown
      assert Message.stop("something_new_2027") == :unknown
      assert Message.stop(%Message{stop_reason: nil}) == :unknown
    end
  end
end

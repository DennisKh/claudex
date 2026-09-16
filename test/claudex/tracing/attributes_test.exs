defmodule Claudex.Tracing.AttributesTest do
  @moduledoc """
  The vocabulary, one builder at a time, including the values that arrive when
  something went wrong: a body with no reply in it, a tool that returned its
  failure, a stream that never got a first chunk.
  """

  use ExUnit.Case, async: false

  alias Claudex.{Message, Usage}
  alias Claudex.Tracing.Attributes

  @messages_path "/v1/messages"

  setup do
    Application.put_env(:claudex, :trace_content, true)
    on_exit(fn -> Application.delete_env(:claudex, :trace_content) end)

    :ok
  end

  defp metadata(path, extra) do
    Map.merge(%{method: :post, path: path}, extra)
  end

  describe "request/2" do
    test "a messages request is named and marked as a generation" do
      {name, attributes} =
        Attributes.request(metadata(@messages_path, %{model: "claude-opus-5"}),
          json: %{model: "claude-opus-5", max_tokens: 64, temperature: 0.5, messages: []}
        )

      assert name == "chat claude-opus-5"
      assert attributes["gen_ai.system"] == "anthropic"
      assert attributes["gen_ai.operation.name"] == "chat"
      assert attributes["gen_ai.request.model"] == "claude-opus-5"
      assert attributes["gen_ai.request.max_tokens"] == 64
      assert attributes["gen_ai.request.temperature"] == 0.5
      assert attributes["http.request.method"] == "POST"
      assert attributes["url.path"] == @messages_path
    end

    test "absent optional parameters are absent, not nil" do
      {_name, attributes} =
        Attributes.request(metadata(@messages_path, %{model: "m"}), json: %{model: "m"})

      refute Map.has_key?(attributes, "gen_ai.request.max_tokens")
      refute Map.has_key?(attributes, "gen_ai.request.temperature")
    end
  end

  describe "response/2" do
    test "reads the id, the snapshot model, the tokens and the stop reason" do
      body = %{
        "id" => "msg_1",
        "model" => "claude-haiku-4-5-20251001",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 15, "output_tokens" => 5},
        "content" => [%{"type" => "text", "text" => "42"}]
      }

      attributes = Attributes.response(body, 200)

      assert attributes["gen_ai.response.id"] == "msg_1"
      assert attributes["gen_ai.response.model"] == "claude-haiku-4-5-20251001"
      assert attributes["gen_ai.usage.input_tokens"] == 15
      assert attributes["gen_ai.usage.output_tokens"] == 5
      assert attributes["gen_ai.response.finish_reasons"] == ["end_turn"]
      assert attributes["http.response.status_code"] == 200
    end

    test "a body that is not a map at all is just the status" do
      assert Attributes.response("<html>", 502) == %{"http.response.status_code" => 502}
    end
  end

  describe "stream/1" do
    test "records what went past and how soon the first of it did" do
      started = System.monotonic_time()
      first = started + System.convert_time_unit(120, :millisecond, :native)

      attributes =
        Attributes.stream(%{
          chunks: 6,
          bytes: 1757,
          started: started,
          first_chunk: first,
          status: 200
        })

      assert attributes["claudex.stream.events"] == 6
      assert attributes["claudex.stream.bytes"] == 1757
      assert attributes["claudex.stream.time_to_first_chunk_ms"] == 120
      assert attributes["http.response.status_code"] == 200
    end

    test "a stream that never produced a chunk reports no time to one" do
      attributes =
        Attributes.stream(%{
          chunks: 0,
          bytes: 0,
          started: System.monotonic_time(),
          first_chunk: nil,
          status: nil
        })

      refute Map.has_key?(attributes, "claudex.stream.time_to_first_chunk_ms")
      refute Map.has_key?(attributes, "http.response.status_code")
    end
  end

  describe "turn/1 and conversation/3" do
    test "a turn shares one name across a run and carries its index" do
      assert {"turn", %{"claudex.turn.index" => 1}} = Attributes.turn(1)
      assert {"turn", %{"claudex.turn.index" => 7}} = Attributes.turn(7)
    end

    test "a conversation is an agent invocation, named for the model" do
      {name, attributes} =
        Attributes.conversation(%{model: "claude-opus-5", messages: []}, 20, "chat-1")

      assert name == "invoke_agent claude-opus-5"
      assert attributes["gen_ai.operation.name"] == "invoke_agent"
      assert attributes["claudex.turn.max"] == 20
      assert attributes["session.id"] == "chat-1"
    end
  end

  describe "tool/2 and tool_outcome/2" do
    test "names the span for the tool and records its arguments" do
      {name, attributes} = Attributes.tool("add", %{"a" => 1})

      assert name == "execute_tool add"
      assert attributes["gen_ai.operation.name"] == "execute_tool"
      assert attributes["gen_ai.tool.name"] == "add"
      assert attributes["gen_ai.tool.type"] == "function"
      assert attributes["gen_ai.tool.call.arguments"] =~ ~s("a":1)
    end

    test "records what the tool returned, not how Claudex tagged it" do
      attributes = Attributes.tool_outcome(:ok, {:ok, 42})

      assert attributes["claudex.tool.outcome"] == "ok"
      assert attributes["gen_ai.tool.call.result"] == "42"
    end

    test "a string result is the string, not a JSON-quoted one" do
      attributes = Attributes.tool_outcome(:ok, {:ok, "42 degrees"})

      assert attributes["gen_ai.tool.call.result"] == "42 degrees"
    end

    test "content JSON cannot carry is described rather than raised over" do
      # A tool that reads a file hands back bytes. The attributes are built
      # outside every tracer guard, so raising here reaches the caller.
      for value <- [<<0x89, 0xFF>>, self(), make_ref(), {:a, :tuple}] do
        assert %{"gen_ai.tool.call.result" => recorded} =
                 Attributes.tool_outcome(:ok, {:ok, value})

        assert String.valid?(recorded)
      end
    end
  end

  describe "tool_error/1" do
    test "a tool that returned a failure gives the message for the span status" do
      assert Attributes.tool_error({:error, %{message: "cannot divide by zero"}}) ==
               "cannot divide by zero"
    end

    test "a failure with no message is described" do
      assert Attributes.tool_error({:error, :nope}) == ":nope"
    end

    test "a tool that worked has no error" do
      assert Attributes.tool_error({:ok, 42}) == nil
    end
  end

  describe "error_message/2" do
    test "prefers the message the API sent" do
      body = %{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}}

      assert Attributes.error_message(body, 429) == "slow down"
    end

    test "falls back to the status when there is no message to quote" do
      assert Attributes.error_message(%{}, 500) == "HTTP 500"
      assert Attributes.error_message("", 502) == "HTTP 502"
    end
  end

  describe "reply/1" do
    test "reads a decoded message, which is all a streamed reply leaves behind" do
      message = %Message{
        id: "msg_1",
        model: "claude-haiku-4-5-20251001",
        role: "assistant",
        stop_reason: "tool_use",
        usage: %Usage{input_tokens: 15, output_tokens: 5},
        content: []
      }

      attributes = Attributes.reply(message)

      assert attributes["gen_ai.response.id"] == "msg_1"
      assert attributes["gen_ai.response.model"] == "claude-haiku-4-5-20251001"
      assert attributes["gen_ai.usage.input_tokens"] == 15
      assert attributes["gen_ai.response.finish_reasons"] == ["tool_use"]
    end

    test "a message with no usage yet records none" do
      attributes = Attributes.reply(%Message{id: "msg_1", role: "assistant", content: []})

      refute Map.has_key?(attributes, "gen_ai.usage.input_tokens")
      refute Map.has_key?(attributes, "gen_ai.response.finish_reasons")
    end
  end
end

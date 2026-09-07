defmodule Claudex.ContentBlockTest do
  use ExUnit.Case, async: true

  alias Claudex.ContentBlock
  alias Claudex.ContentBlock.{RedactedThinking, Text, Thinking, ToolUse, Unknown}

  test "decodes a text block" do
    assert %Text{text: "hi", citations: []} =
             ContentBlock.decode(%{"type" => "text", "text" => "hi"})
  end

  test "decodes a thinking block" do
    json = %{"type" => "thinking", "thinking" => "let me see", "signature" => "sig"}

    assert %Thinking{thinking: "let me see", signature: "sig"} = ContentBlock.decode(json)
  end

  test "decodes a redacted_thinking block" do
    json = %{"type" => "redacted_thinking", "data" => "opaque"}

    assert %RedactedThinking{data: "opaque"} = ContentBlock.decode(json)
  end

  test "decodes a tool_use block" do
    json = %{
      "type" => "tool_use",
      "id" => "toolu_1",
      "name" => "get_weather",
      "input" => %{"city" => "SF"}
    }

    assert %ToolUse{id: "toolu_1", name: "get_weather", input: %{"city" => "SF"}} =
             ContentBlock.decode(json)
  end

  test "falls back to Unknown for an unmodeled block type" do
    json = %{"type" => "server_tool_use", "id" => "srvtoolu_1"}

    assert %Unknown{type: "server_tool_use", raw: ^json} = ContentBlock.decode(json)
  end
end

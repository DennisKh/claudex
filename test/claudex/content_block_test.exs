defmodule Claudex.ContentBlockTest do
  use ExUnit.Case, async: true

  alias Claudex.ContentBlock

  alias Claudex.ContentBlock.{
    RedactedThinking,
    ServerToolResult,
    ServerToolUse,
    Text,
    Thinking,
    ToolUse,
    Unknown
  }

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
    json = %{"type" => "mcp_tool_use", "id" => "mcptoolu_1"}

    assert %Unknown{type: "mcp_tool_use", raw: ^json} = ContentBlock.decode(json)
  end

  # The blocks below follow the responses in Anthropic's web search and server
  # tools guides; test/fixtures/server_tools.json records a real one when the
  # live suite runs with recording on.
  describe "server tool blocks" do
    @search_result %{
      "type" => "web_search_result",
      "url" => "https://en.wikipedia.org/wiki/Claude_Shannon",
      "title" => "Claude Shannon - Wikipedia",
      "encrypted_content" => "EqgfCioIARgBIiQ3YTAwMjY1Mi1",
      "page_age" => "April 30, 2025"
    }

    test "decodes a server_tool_use block" do
      json = %{
        "type" => "server_tool_use",
        "id" => "srvtoolu_1",
        "name" => "web_search",
        "input" => %{"query" => "claude shannon birth date"}
      }

      assert %ServerToolUse{id: "srvtoolu_1", name: "web_search", input: input} =
               ContentBlock.decode(json)

      assert input == %{"query" => "claude shannon birth date"}
    end

    test "decodes a search result and says which tool answered" do
      json = %{
        "type" => "web_search_tool_result",
        "tool_use_id" => "srvtoolu_1",
        "content" => [@search_result]
      }

      assert %ServerToolResult{tool: :web_search, tool_use_id: "srvtoolu_1", error_code: nil} =
               block = ContentBlock.decode(json)

      assert block.content == [@search_result]
    end

    test "lifts the error code out of a failed call" do
      json = %{
        "type" => "web_search_tool_result",
        "tool_use_id" => "srvtoolu_1",
        "content" => %{
          "type" => "web_search_tool_result_error",
          "error_code" => "max_uses_exceeded"
        }
      }

      assert %ServerToolResult{tool: :web_search, error_code: "max_uses_exceeded"} =
               ContentBlock.decode(json)
    end

    test "decodes the code execution family too" do
      json = %{
        "type" => "bash_code_execution_tool_result",
        "tool_use_id" => "srvtoolu_2",
        "content" => %{
          "type" => "bash_code_execution_result",
          "stdout" => "hello\n",
          "stderr" => "",
          "return_code" => 0,
          "content" => []
        }
      }

      assert %ServerToolResult{tool: :bash_code_execution, error_code: nil} =
               block = ContentBlock.decode(json)

      assert block.content["stdout"] == "hello\n"
    end

    test "both go back to the API byte for byte" do
      # A result's encrypted_content is rejected if it changes on the way back,
      # so replaying has to hand over the map the API sent, not one rebuilt
      # from the fields Claudex happens to model.
      blocks = [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_1",
          "name" => "web_search",
          "caller" => %{"type" => "direct"},
          "input" => %{"query" => "kyiv"}
        },
        %{
          "type" => "web_search_tool_result",
          "tool_use_id" => "srvtoolu_1",
          "caller" => %{"type" => "direct"},
          "content" => [@search_result]
        }
      ]

      assert Enum.map(blocks, &(&1 |> ContentBlock.decode() |> ContentBlock.to_param())) == blocks
    end
  end
end

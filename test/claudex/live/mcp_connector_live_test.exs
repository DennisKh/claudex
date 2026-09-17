defmodule Claudex.Live.MCPConnectorTest do
  @moduledoc """
  End-to-end coverage of the MCP connector: the API connects to a remote MCP
  server itself and runs the calls, so a reply carries `mcp_tool_use` and
  `mcp_tool_result` blocks and no tool ever runs here.

  The server is DeepWiki's public endpoint, which needs no authorization token
  and answers questions about public GitHub repositories. Nothing but a
  repository name leaves in the call.

  The streaming test is the one that matters for `Claudex.Stream.Accumulator`:
  it settles whether a connector call's arguments arrive in
  `input_json_delta` fragments, which is what decides whether the accumulator
  has to fold them onto the block.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Message, Messages, Stream}
  alias Claudex.ContentBlock.{MCPToolResult, MCPToolUse}
  alias Claudex.Stream.Event

  @moduletag timeout: 180_000

  @beta "mcp-client-2025-11-20"

  @server %Claudex.MCP.Server{name: "deepwiki", url: "https://mcp.deepwiki.com/mcp"}
  @toolset %{type: "mcp_toolset", mcp_server_name: "deepwiki"}

  @prompt """
  Use the deepwiki tools to read the wiki structure of the GitHub repository
  elixir-lang/elixir, then name two of its documentation pages.
  """

  setup do
    {:ok, client: Claudex.new(api_key: @api_key, beta: @beta)}
  end

  defp params do
    %{
      model: @model,
      max_tokens: 2048,
      mcp_servers: [@server],
      tools: [@toolset],
      messages: [Message.user(@prompt)]
    }
  end

  defp find(message, module), do: Enum.find(message.content, &is_struct(&1, module))

  test "a connector call comes back as MCP blocks", %{client: client} do
    {:ok, message} =
      client
      |> Recorder.record_json("mcp_connector")
      |> Messages.create(params())

    call = find(message, MCPToolUse)
    result = find(message, MCPToolResult)

    assert call, "the prompt produced no MCP tool call"
    assert call.server_name == "deepwiki"
    assert call.input != %{}

    assert result.tool_use_id == call.id
    refute result.is_error, "the MCP call failed: #{inspect(result.content)}"

    # Nothing ran locally: the API executed the call before it replied.
    assert Message.tool_uses(message) == []

    assert ContentBlock.to_param(call)["input"] == call.input
    assert ContentBlock.to_param(result) == result.raw
  end

  test "a streamed connector call carries its arguments in deltas", %{client: client} do
    events =
      client
      |> Recorder.record_stream("mcp_connector_stream")
      |> Messages.stream!(params())
      |> Enum.to_list()

    index =
      Enum.find_value(events, fn
        %Event.ContentBlockStart{index: index, content_block: %MCPToolUse{}} -> index
        _event -> nil
      end)

    assert index, "the prompt produced no MCP tool call"

    fragments =
      for %Event.ContentBlockDelta{index: ^index, delta: {:input_json, chunk}} <- events,
          do: chunk

    assert fragments != [],
           "the call's arguments did not arrive as input_json_delta fragments"

    {:ok, message} = Stream.final_message(events)
    call = find(message, MCPToolUse)

    assert call.input == JSON.decode!(Enum.join(fragments))
    assert ContentBlock.to_param(call)["input"] == call.input
  end
end

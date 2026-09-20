defmodule Claudex.ContentBlock.MCPToolUse do
  @moduledoc """
  A tool call Claude made to a tool on an MCP server.

  The API connects to the server and runs the call itself. Its answer arrives
  in the same reply as a `Claudex.ContentBlock.MCPToolResult`, paired by this
  block's `id`. There is nothing to dispatch, so `Claudex.Message.tool_uses/1`
  leaves this block out.

  `server_name` is the name the request gave that server in `mcp_servers`. A
  tool you run yourself arrives as a `Claudex.ContentBlock.ToolUse`.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:id, :name, :server_name, :input, :raw]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          server_name: String.t(),
          input: map(),
          raw: map()
        }

  @doc """
  Returns the map the API sent, with the call's arguments filled in.

  Fields this version doesn't model are kept as they arrived, so the block
  replays into the next request unchanged.
  """
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw} = block) when is_map(raw) do
    # `raw` is the `content_block_start` map, where a streamed call's arguments
    # are still empty: the real ones arrived afterwards, as JSON fragments.
    Map.put(raw, "input", block.input)
  end

  def to_param(%__MODULE__{} = block) do
    %{
      type: "mcp_tool_use",
      id: block.id,
      name: block.name,
      server_name: block.server_name,
      input: block.input
    }
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      id: json["id"],
      name: json["name"],
      server_name: json["server_name"],
      input: json["input"] || %{},
      raw: json
    }
  end
end

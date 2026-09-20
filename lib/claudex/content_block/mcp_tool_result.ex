defmodule Claudex.ContentBlock.MCPToolResult do
  @moduledoc """
  What a tool on an MCP server sent back, paired to its
  `Claudex.ContentBlock.MCPToolUse` by `tool_use_id`.

  `content` is the server's own payload, either a string or a list of text
  blocks. A failed call is still a 200 with this block in it, and `is_error`
  tells the two apart.

      case block do
        %MCPToolResult{is_error: true, content: content} -> log(content)
        %MCPToolResult{content: content} -> render(content)
      end
  """

  @behaviour Claudex.ContentBlock

  defstruct [:tool_use_id, :content, :is_error, :raw]

  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          content: String.t() | list() | nil,
          is_error: boolean(),
          raw: map()
        }

  @doc """
  Joins the text of an MCP result into one string.

  `content` is a string for a plain answer, or a list of blocks. A string comes
  back as it is; blocks that are not text are skipped and the rest are joined
  with a newline, since a server sends them as separate items rather than as
  fragments of one. A payload shaped some other way is `""`, so a result type a
  later API adds reads as no text rather than raising.

      Claudex.ContentBlock.MCPToolResult.text(block)
      #=> "Here is the result of the MCP tool"
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) when is_binary(content), do: content

  def text(%__MODULE__{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  def text(%__MODULE__{}), do: ""

  @doc """
  Returns the map the API sent, unchanged.

  Fields this version doesn't model are kept, so the block replays into the
  next request as it arrived.
  """
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}), do: raw

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      tool_use_id: json["tool_use_id"],
      content: json["content"],
      is_error: json["is_error"],
      raw: json
    }
  end
end

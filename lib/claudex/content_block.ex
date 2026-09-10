defmodule Claudex.ContentBlock do
  @moduledoc """
  One block of content in a message. A reply from Claude is a list of
  these — usually just text, sometimes thinking or a tool call mixed in.
  `decode/1` reads a block's `"type"` field and returns the matching
  struct.
  """

  alias Claudex.ContentBlock.{
    RedactedThinking,
    ServerToolResult,
    ServerToolUse,
    Text,
    Thinking,
    ToolUse,
    Unknown
  }

  @type t ::
          Text.t()
          | Thinking.t()
          | RedactedThinking.t()
          | ToolUse.t()
          | ServerToolUse.t()
          | ServerToolResult.t()
          | Unknown.t()

  @doc """
  Decodes one content block. Falls back to `Claudex.ContentBlock.Unknown`
  for a block type not modeled yet, so a new block type from the API never
  breaks decoding — it just arrives un-typed.
  """
  @spec decode(map()) :: t()
  def decode(%{"type" => "text"} = json), do: Text.decode(json)
  def decode(%{"type" => "thinking"} = json), do: Thinking.decode(json)
  def decode(%{"type" => "redacted_thinking"} = json), do: RedactedThinking.decode(json)
  def decode(%{"type" => "tool_use"} = json), do: ToolUse.decode(json)
  def decode(%{"type" => "server_tool_use"} = json), do: ServerToolUse.decode(json)

  # One clause per tool the API runs itself. They differ only in what `content`
  # holds, which the struct keeps as the API sent it.
  for type <- ServerToolResult.types() do
    def decode(%{"type" => unquote(type)} = json), do: ServerToolResult.decode(json)
  end

  def decode(json), do: Unknown.decode(json)

  @doc """
  Turns a decoded block back into the map the API expects in a request, so a
  reply can be sent straight back as conversation history.

  A map is passed through untouched, so hand-written blocks keep working.
  """
  @spec to_param(t() | map()) :: map()
  def to_param(%Text{} = block), do: Text.to_param(block)
  def to_param(%Thinking{} = block), do: Thinking.to_param(block)
  def to_param(%RedactedThinking{} = block), do: RedactedThinking.to_param(block)
  def to_param(%ToolUse{} = block), do: ToolUse.to_param(block)
  def to_param(%ServerToolUse{} = block), do: ServerToolUse.to_param(block)
  def to_param(%ServerToolResult{} = block), do: ServerToolResult.to_param(block)
  def to_param(%Unknown{} = block), do: Unknown.to_param(block)
  def to_param(%{} = block), do: block
end

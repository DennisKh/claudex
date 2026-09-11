defmodule Claudex.ContentBlock do
  @moduledoc """
  One block of content in a message. A reply from Claude is a list of
  these — usually just text, sometimes thinking or a tool call mixed in.
  `decode/1` reads a block's `"type"` field and returns the matching
  struct.

  Each block type is a module implementing this behaviour, with `decode/1`
  reading the API's map and `to_param/1` writing it back:

    * `Claudex.ContentBlock.Text`: what Claude wrote, with any citations
    * `Claudex.ContentBlock.Thinking` and
      `Claudex.ContentBlock.RedactedThinking`: its extended thinking
    * `Claudex.ContentBlock.ToolUse`: a call to one of your tools
    * `Claudex.ContentBlock.ServerToolUse` and
      `Claudex.ContentBlock.ServerToolResult`: a call to one the API runs
      itself, and its answer A type Claudex doesn't model yet
  becomes a `Claudex.ContentBlock.Unknown`, which keeps the raw map so the
  block still replays into the next request.

  `Claudex.Message` holds them, and `Claudex.Stream.Accumulator` assembles them
  from a stream.
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

  @doc "Reads one block of the API's JSON into this module's struct."
  @callback decode(map()) :: t()

  @doc "Writes the struct back into the map the API expects in a request."
  @callback to_param(t()) :: map()

  # The API's name for a block, and the module that handles it. Every tool the
  # API runs itself lands on one module: those blocks differ only in what
  # `content` holds, which the struct keeps as the API sent it.
  @blocks Map.merge(
            %{
              "text" => Text,
              "thinking" => Thinking,
              "redacted_thinking" => RedactedThinking,
              "tool_use" => ToolUse,
              "server_tool_use" => ServerToolUse
            },
            Map.new(ServerToolResult.types(), &{&1, ServerToolResult})
          )

  @modules [Unknown | Map.values(@blocks)] |> Enum.uniq()

  @doc """
  Decodes one content block. Falls back to `Claudex.ContentBlock.Unknown`
  for a block type not modeled yet, so a new block type from the API never
  breaks decoding — it just arrives un-typed.
  """
  @spec decode(map()) :: t()
  for {type, module} <- @blocks do
    def decode(%{"type" => unquote(type)} = json), do: unquote(module).decode(json)
  end

  def decode(json), do: Unknown.decode(json)

  @doc """
  Turns a decoded block back into the map the API expects in a request, so a
  reply can be sent straight back as conversation history.

  A map is passed through untouched, so hand-written blocks keep working.
  """
  @spec to_param(t() | map()) :: map()
  def to_param(%module{} = block) when module in @modules, do: module.to_param(block)
  def to_param(%{} = block), do: block
end

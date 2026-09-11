defmodule Claudex.ContentBlock.ServerToolUse do
  @moduledoc """
  A tool call Claude made to a tool the API runs itself, such as `web_search`.

  The result arrives as a `Claudex.ContentBlock.ServerToolResult` in the same reply,
  paired by this block's `id`. A call whose result is missing runs at the start of
  the next request, so the reply goes back into `messages` as it came.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:id, :name, :input, :raw]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map(),
          raw: map()
        }

  @doc """
  Returns the block exactly as the API sent it.

  Fields like `caller` have no struct of their own, and a call Claude has yet
  to make has to go back untouched, so the raw map is what gets replayed.
  """
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw} = block) when is_map(raw) do
    # `raw` is the `content_block_start` map, where a streamed call's arguments
    # are still empty: the real ones arrived afterwards, as JSON fragments.
    Map.put(raw, "input", block.input)
  end

  def to_param(%__MODULE__{} = block) do
    %{type: "server_tool_use", id: block.id, name: block.name, input: block.input}
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{id: json["id"], name: json["name"], input: json["input"] || %{}, raw: json}
  end
end

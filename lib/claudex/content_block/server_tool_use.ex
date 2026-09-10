defmodule Claudex.ContentBlock.ServerToolUse do
  @moduledoc """
  A tool call Claude made to a tool the API runs itself, such as `web_search`.

  The result arrives as a `Claudex.ContentBlock.ServerToolResult` in the same reply,
  paired by this block's `id`. A call whose result is missing runs at the start of
  the next request, so the reply goes back into `messages` as it came.
  """

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
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}), do: raw

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{id: json["id"], name: json["name"], input: json["input"] || %{}, raw: json}
  end
end

defmodule Claudex.ContentBlock.Unknown do
  @moduledoc """
  A content block type this version of Claudex doesn't have a struct for
  yet, an MCP tool call for example. Nothing is lost: `raw` holds the full
  decoded JSON, and `type` is its `"type"` field.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:type, :raw]

  @type t :: %__MODULE__{type: String.t(), raw: map()}

  @doc """
  Returns the block exactly as the API sent it, so a type Claudex doesn't model
  yet still round-trips into the next request without losing anything.
  """
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}), do: raw

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{type: json["type"], raw: json}
  end
end

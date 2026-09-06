defmodule Claudex.ContentBlock.Text do
  @moduledoc "A block of text Claude generated, with any citations it attached."

  defstruct [:text, citations: []]

  @type t :: %__MODULE__{text: String.t(), citations: [map()]}

  @doc "Turns the block back into the map the API expects in a request."
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{citations: []} = block), do: %{type: "text", text: block.text}

  def to_param(%__MODULE__{} = block) do
    %{type: "text", text: block.text, citations: block.citations}
  end

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{text: json["text"], citations: json["citations"] || []}
  end
end

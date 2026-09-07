defmodule Claudex.ContentBlock.Thinking do
  @moduledoc """
  One step of Claude's extended thinking. If you're continuing a
  conversation that used tools, pass this block back to the API exactly as
  received, `signature` included — don't edit or regenerate it.
  """

  defstruct [:thinking, :signature]

  @type t :: %__MODULE__{thinking: String.t(), signature: String.t()}

  @doc """
  Turns the block back into the map the API expects in a request.

  Send it back exactly as it arrived — the API rejects a request whose thinking
  blocks were edited, and that includes ones whose text is empty.
  """
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{} = block) do
    %{type: "thinking", thinking: block.thinking, signature: block.signature}
  end

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{thinking: json["thinking"], signature: json["signature"]}
  end
end

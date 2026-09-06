defmodule Claudex.ContentBlock.ToolUse do
  @moduledoc """
  A request from Claude to call one of the tools you provided. Run it with
  `input`, then send the result back as a `tool_result` block on your next
  message, matched to this block's `id`.
  """

  defstruct [:id, :name, :input]

  @type t :: %__MODULE__{id: String.t(), name: String.t(), input: map()}

  @doc "Turns the block back into the map the API expects in a request."
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{} = block) do
    %{type: "tool_use", id: block.id, name: block.name, input: block.input}
  end

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{id: json["id"], name: json["name"], input: json["input"] || %{}}
  end
end

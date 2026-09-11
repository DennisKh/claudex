defmodule Claudex.ContentBlock.ToolUse do
  @moduledoc """
  A request from Claude to call one of the tools you provided. Run it with
  `Claudex.Tool.call/3`, build the answer with `Claudex.Tool.result/3`, and
  send it back on your next message, matched to this block's `id`.
  `Claudex.ToolRunner` does all of that. `Claudex.Message.tool_uses/1` picks
  these out of a reply, and a tool the API runs itself arrives as a
  `Claudex.ContentBlock.ServerToolUse` instead.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:id, :name, :input]

  @type t :: %__MODULE__{id: String.t(), name: String.t(), input: map()}

  @doc "Turns the block back into the map the API expects in a request."
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{} = block) do
    %{type: "tool_use", id: block.id, name: block.name, input: block.input}
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{id: json["id"], name: json["name"], input: json["input"] || %{}}
  end
end

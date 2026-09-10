defmodule Claudex.ContentBlock.RedactedThinking do
  @moduledoc """
  A thinking step Claude redacted for safety. `data` is opaque and
  encrypted — there's nothing to read here. Pass it back to the API
  unchanged when continuing the conversation: dropping one of these from an
  assistant message you echo back is a 400.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:data]

  @type t :: %__MODULE__{data: String.t()}

  @doc "Turns the block back into the map the API expects in a request."
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{} = block), do: %{type: "redacted_thinking", data: block.data}

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{data: json["data"]}
  end
end

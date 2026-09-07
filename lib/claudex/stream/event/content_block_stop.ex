defmodule Claudex.Stream.Event.ContentBlockStop do
  @moduledoc "The content block at `index` is complete."

  defstruct [:index]

  @type t :: %__MODULE__{index: non_neg_integer()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json), do: %__MODULE__{index: json["index"]}
end

defmodule Claudex.Stream.Event.ContentBlockStop do
  @moduledoc """
  The content block at `index` is complete. A tool call's arguments are only
  parseable now, which is where `Claudex.Stream.Accumulator` decodes them.
  """

  defstruct [:index]

  @type t :: %__MODULE__{index: non_neg_integer()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json), do: %__MODULE__{index: json["index"]}
end

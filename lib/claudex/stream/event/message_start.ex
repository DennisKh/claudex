defmodule Claudex.Stream.Event.MessageStart do
  @moduledoc """
  The first event of a stream. Carries the `Claudex.Message` shell, with id,
  model, role and usage so far, and empty content that the later events fill
  in. `Claudex.Stream.Accumulator` is what fills it.
  """

  alias Claudex.Message

  defstruct [:message]

  @type t :: %__MODULE__{message: Message.t()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json), do: %__MODULE__{message: Message.decode(json["message"] || %{})}
end

defmodule Claudex.Stream.Event.MessageStart do
  @moduledoc """
  The first event of a stream. Carries the `Claudex.Message` shell, with id,
  model, role and usage so far. Its content is usually empty and filled in by
  the later events, but the continuation of a programmatic tool call can
  arrive whole here, followed only by `message_stop`.
  `Claudex.Stream.Accumulator` assembles both.
  """

  alias Claudex.Message

  defstruct [:message]

  @type t :: %__MODULE__{message: Message.t()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json), do: %__MODULE__{message: Message.decode(json["message"] || %{})}
end

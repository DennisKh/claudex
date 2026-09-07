defmodule Claudex.Stream.Event.MessageStart do
  @moduledoc """
  The first event of a stream. Carries the message shell — id, model, role,
  usage so far — with empty content that the later events fill in.
  """

  alias Claudex.Message

  defstruct [:message]

  @type t :: %__MODULE__{message: Message.t()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json), do: %__MODULE__{message: Message.decode(json["message"] || %{})}
end

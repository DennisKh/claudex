defmodule Claudex.Stream.SSE.Event do
  @moduledoc """
  One raw Server-Sent Event: its name, its data, and the two reconnection
  fields the SSE spec defines.

  This is the wire shape, before anything Claude-specific happens to it:
  `data` is still the undecoded string the server sent, which
  `Claudex.Stream.Event.decode/1` turns into a typed event.
  """

  defstruct [:name, :id, :retry, data: ""]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          data: String.t(),
          id: String.t() | nil,
          retry: non_neg_integer() | nil
        }
end

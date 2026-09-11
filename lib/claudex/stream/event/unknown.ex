defmodule Claudex.Stream.Event.Unknown do
  @moduledoc """
  A stream event this version of Claudex doesn't model yet. Nothing is lost:
  `raw` holds the full decoded JSON and `type` is its `"type"` field, so a
  new event type from the API never breaks a running stream.
  `Claudex.Stream.Event` lists the ones that are modelled.
  """

  defstruct [:type, :raw]

  @type t :: %__MODULE__{type: String.t() | nil, raw: map()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json), do: %__MODULE__{type: json["type"], raw: json}
end

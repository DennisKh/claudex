defmodule Claudex.Stream.Event.MessageStop do
  @moduledoc """
  The last event of a stream. Nothing follows it, and
  `Claudex.Stream.Accumulator.message/1` holds the finished
  `Claudex.Message`.
  """

  defstruct []

  @type t :: %__MODULE__{}

  @doc false
  @spec decode(map()) :: t()
  def decode(_json), do: %__MODULE__{}
end

defmodule Claudex.Stream.Event.MessageStop do
  @moduledoc "The last event of a stream. Nothing follows it."

  defstruct []

  @type t :: %__MODULE__{}

  @doc false
  @spec decode(map()) :: t()
  def decode(_json), do: %__MODULE__{}
end

defmodule Claudex.JSONL do
  @moduledoc """
  Splits a JSON Lines byte stream into complete lines — the format the Message
  Batches API uses for results.

  Pure and incremental, like `Claudex.Stream.SSE`: feed it whatever bytes
  arrived, get back the lines those bytes completed and a decoder holding the
  rest. Turning a line into JSON is the caller's job, so a malformed line can
  be reported with its contents instead of surfacing as a decode error from
  somewhere deeper.
  """

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @doc "Builds a decoder with an empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds `chunk` to the decoder, returning the lines it completed and a decoder
  holding the partial line at the end. Blank lines are dropped.
  """
  @spec decode(t(), binary()) :: {[binary()], t()}
  def decode(%__MODULE__{buffer: buffer}, chunk) do
    [partial | complete] = (buffer <> chunk) |> String.split("\n") |> Enum.reverse()

    {complete |> Enum.reverse() |> Enum.reject(&blank?/1), %__MODULE__{buffer: partial}}
  end

  @doc """
  Drains the buffer, returning a final line that arrived without a trailing
  newline.
  """
  @spec flush(t()) :: {[binary()], t()}
  def flush(%__MODULE__{buffer: buffer}) do
    if blank?(buffer), do: {[], new()}, else: {[buffer], new()}
  end

  defp blank?(line), do: String.trim(line) == ""
end

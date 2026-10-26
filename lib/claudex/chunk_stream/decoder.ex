defmodule Claudex.ChunkStream.Decoder do
  @moduledoc false

  @typedoc "A decoder's state: whatever it carries between chunks."
  @type t :: term()

  @doc "Builds a decoder holding nothing yet."
  @callback new() :: t()

  @doc """
  Feeds `chunk` to the decoder, returning the items it completed and a decoder
  carrying whatever is still incomplete.
  """
  @callback decode(t(), chunk :: binary()) :: {[term()], t()}

  @doc """
  Drains the decoder once the body has ended, returning any item it still held
  and an empty decoder.
  """
  @callback flush(t()) :: {[term()], t()}
end

defmodule Claudex.TestSupport.Fixtures do
  @moduledoc """
  Reads the payloads `Claudex.TestSupport.Recorder` captured from the real API.

  The offline tests replay these, so a fixture going stale shows up as a
  failing decode rather than as a hand-written map that quietly disagrees with
  what the API sends.
  """

  @dir "test/fixtures"

  @doc "Reads a recorded JSON response as a decoded map."
  @spec json!(String.t()) :: map()
  def json!(name), do: name |> path(".json") |> File.read!() |> Jason.decode!()

  @doc "Reads a recorded SSE response as the raw bytes the server sent."
  @spec sse!(String.t()) :: binary()
  def sse!(name), do: name |> path(".sse") |> File.read!()

  @doc "Splits a recorded SSE response into chunks of `size` bytes."
  @spec chunks(binary(), pos_integer()) :: [binary()]
  def chunks(sse, size) do
    sse
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  defp path(name, extension), do: Path.join(@dir, name <> extension)
end

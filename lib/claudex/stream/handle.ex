defmodule Claudex.Stream.Handle do
  @moduledoc """
  Identifies a stream started with `Claudex.Messages.stream_to/3`.

  `ref` is the tag on every message the stream sends you; `pid` is the
  process running the stream, which `Claudex.Stream.cancel/1` talks to. It
  exits once the stream's last message has been sent.
  """

  defstruct [:ref, :pid]

  @type t :: %__MODULE__{ref: reference(), pid: pid()}
end

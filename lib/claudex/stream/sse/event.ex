defmodule Claudex.Stream.SSE.Event do
  @moduledoc false

  defstruct [:name, :id, :retry, data: ""]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          data: String.t(),
          id: String.t() | nil,
          retry: non_neg_integer() | nil
        }
end

defmodule Claudex.TestSupport.Ticket do
  @moduledoc """
  A struct with one field of every shape the output format has to handle: a
  constrained integer, a literal union, a non-empty list, a stdlib struct that
  maps to a string format, a nested struct, and an undescribed map.
  """

  defmodule Reporter do
    @moduledoc false

    defstruct [:name, :email]

    @type t :: %__MODULE__{name: String.t(), email: String.t() | nil}
  end

  defstruct [:id, :title, :priority, :tags, :due, :reporter, :metadata]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          title: String.t(),
          priority: :low | :high,
          tags: nonempty_list(String.t()),
          due: Date.t() | nil,
          reporter: Reporter.t(),
          metadata: map()
        }
end

defmodule Claudex.TestSupport.Vague do
  @moduledoc "A struct whose field has no type an output format can carry."

  defstruct [:notes]

  @type t :: %__MODULE__{notes: any()}
end

defmodule Claudex.TestSupport.Tupled do
  @moduledoc "A struct whose field is a tuple, which has no JSON shape."

  defstruct [:pair]

  @type t :: %__MODULE__{pair: {String.t(), integer()}}
end

defmodule Claudex.TestSupport.Bare do
  @moduledoc "A struct with no `@type t` at all, the shape a stripped release leaves behind."

  defstruct [:a, :b]
end

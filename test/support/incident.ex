defmodule Claudex.TestSupport.Incident do
  @moduledoc """
  A struct that builds its schema with `use Claudex.Schema`, nesting another
  that does too. Both compile in the same build as the code that reads them.
  """

  defmodule Reporter do
    @moduledoc false
    use Claudex.Schema

    defstruct [:name, :email]

    @type t :: %__MODULE__{name: String.t(), email: String.t() | nil}
  end

  use Claudex.Schema

  defstruct [:summary, :severity, :affected_users, :reporter]

  @type t :: %__MODULE__{
          summary: String.t(),
          severity: :minor | :major,
          affected_users: non_neg_integer(),
          reporter: Reporter.t()
        }
end

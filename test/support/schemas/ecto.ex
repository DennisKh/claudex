defmodule Claudex.TestSupport.Schemas.EctoUser do
  @moduledoc false
  use Ecto.Schema

  schema "users" do
    field(:name, :string)
  end
end

defmodule Claudex.TestSupport.Schemas.EctoComment do
  @moduledoc false
  use Ecto.Schema

  schema "comments" do
    field(:body, :string)
    field(:ecto_ticket_id, :id)
  end
end

defmodule Claudex.TestSupport.Schemas.EctoAddress do
  @moduledoc false
  use Ecto.Schema

  embedded_schema do
    field(:city, :string)
    field(:zip, :string)
  end
end

defmodule Claudex.TestSupport.Schemas.EctoTicket do
  @moduledoc false
  use Ecto.Schema

  alias Claudex.TestSupport.Schemas.{EctoAddress, EctoComment, EctoUser}

  schema "tickets" do
    field(:subject, :string)
    field(:status, Ecto.Enum, values: [:open, :closed])
    field(:tags, {:array, :string})
    field(:price, :decimal)
    field(:opened_at, :naive_datetime)
    embeds_one(:address, EctoAddress)
    belongs_to(:assignee, EctoUser)
    has_many(:comments, EctoComment)
  end
end

defmodule Claudex.TestSupport.Schemas.Reflected do
  @moduledoc """
  The three Ecto field types Claudex can't map, reachable only through the
  reflection it reads.

  Written by hand rather than with `Ecto.Schema`, which rejects all three at
  compile time. The schemas above are real, and cover the shapes that work.
  """

  defmodule NotAnEctoType do
    @moduledoc false
  end

  defmodule NotASchema do
    @moduledoc false
  end

  defmodule CustomType do
    @moduledoc false

    defstruct [:custom]

    @doc false
    def __schema__(:fields), do: [:custom]
    def __schema__(:type, :custom), do: NotAnEctoType
  end

  defmodule UnknownType do
    @moduledoc false

    defstruct [:mystery]

    @doc false
    def __schema__(:fields), do: [:mystery]
    def __schema__(:type, :mystery), do: {:parameterized, {SomethingElse, %{}}}
  end

  defmodule BadEmbed do
    @moduledoc false

    defstruct [:embedded]

    @doc false
    def __schema__(:fields), do: [:embedded]

    def __schema__(:type, :embedded) do
      {:parameterized, {Ecto.Embedded, %{cardinality: :one, related: NotASchema}}}
    end
  end
end

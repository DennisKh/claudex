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

defmodule Claudex.TestSupport.Schemas.Address do
  @moduledoc false
  defstruct [:city, :zip]
  @type t :: %__MODULE__{city: String.t(), zip: String.t() | nil}
end

defmodule Claudex.TestSupport.Schemas.Ticket do
  @moduledoc false
  defstruct [:id, :subject, :status, :address]

  @type t :: %__MODULE__{
          id: integer(),
          subject: String.t(),
          status: :open | :closed,
          address: Claudex.TestSupport.Schemas.Address.t() | nil
        }
end

defmodule Claudex.TestSupport.Schemas.Node do
  @moduledoc false
  defstruct [:value, :next]
  @type t :: %__MODULE__{value: integer(), next: t() | nil}
end

defmodule Claudex.TestSupport.Schemas.Untyped do
  @moduledoc false
  defstruct [:a, :b]
end

defmodule Claudex.TestSupport.Account do
  @moduledoc """
  A struct that, like most in a Phoenix or Ecto app, implements only
  `Jason.Encoder` and keeps a field out of what it encodes.
  """

  @derive {Jason.Encoder, only: [:name]}
  defstruct [:name, :password_hash]
end

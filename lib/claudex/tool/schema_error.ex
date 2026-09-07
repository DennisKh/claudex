defmodule Claudex.Tool.SchemaError do
  @moduledoc """
  Raised at compile time when `Claudex.Tool` can't turn a `@spec` argument
  type into a JSON schema — a typespec construct Claudex doesn't map (a
  function type, a bare `pid()`, an unrecognized Ecto field type, ...), or
  a `Mod.t()` reference that isn't a loaded struct or Ecto schema.

  Fix the `@spec`, or skip type inference for that tool entirely by
  passing `args_schema:` in the `@tool` options — when it's set, the
  `@spec` is never even inspected, so nothing here can raise.
  """

  defexception [:message]
end

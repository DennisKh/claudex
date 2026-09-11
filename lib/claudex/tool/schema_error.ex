defmodule Claudex.Tool.SchemaError do
  @moduledoc """
  Raised when a type can't become a JSON schema: a typespec construct Claudex
  doesn't map (a function type, a bare `pid()`, an unrecognized Ecto field
  type), or a `Mod.t()` reference that isn't a loaded struct or Ecto schema.

  `Claudex.Tool` raises it at compile time while reading a `@spec`, where
  `args_schema:` in the `@tool` options skips inference for that tool.
  `Claudex.OutputFormat` raises it while building a request from a struct's
  `@type t`, where a hand-written `output_config.format` does the same.
  """

  defexception [:message]
end

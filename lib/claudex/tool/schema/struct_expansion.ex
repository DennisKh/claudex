defmodule Claudex.Tool.Schema.StructExpansion do
  @moduledoc """
  Expands a struct module into JSON schema object properties, for the
  `Mod.t()` references `Claudex.Tool.Schema` finds in a `@spec` that
  aren't one of the built-in types.

  Two sources of field info, tried in this order:

    * an Ecto schema — read via the module's own `__schema__/1`
      reflection. Claudex has no compile-time dependency on Ecto; this
      only runs when the referenced module itself implements `__schema__/1`,
      so it works whether or not your project has Ecto installed at all.
      Verified against Ecto 3.14 — a field whose type Claudex doesn't
      recognize (an older Ecto's internal representation for a
      parameterized type, or a custom `Ecto.Type` that doesn't implement
      `type/0`) raises `Claudex.Tool.SchemaError` rather than silently
      producing a wrong schema. Association fields (`belongs_to`,
      `has_many`, `has_one`, `many_to_many`) are skipped — Ecto doesn't
      even include them in `__schema__(:fields)`, and expanding them would
      risk unbounded recursion through relationship graphs anyway. Embeds
      (`embeds_one`, `embeds_many`) are genuine data, not a relationship,
      and are expanded.
    * a plain struct with `@type t :: %__MODULE__{...}` — read from the
      module's own compiled typespec via `Code.Typespec`.

  A struct with neither still expands, with every field left unconstrained
  (`%{}`) — the field names alone are more useful to Claude than nothing,
  and "no type info at all" isn't the same failure as "a type Claudex
  can't map."

  Ecto doesn't expose which fields are `NOT NULL`, so an Ecto-backed
  object's `required` list is always empty. A plain struct's `required`
  list is inferred from its typespec: a field typed `t | nil` (or bare
  `nil`) is optional, anything else is required.

  Every object built here sets `additionalProperties: false`, since the
  field set is known and closed — the same thing `Claudex.Tool` does for
  the top-level `input_schema`, and what a tool declared `strict: true`
  needs at every level rather than only the outermost one.
  """

  alias Claudex.Tool.Schema
  alias Claudex.Tool.SchemaError

  @doc """
  Expands `module` into an object schema.

  Returns `:cycle` when `module` was already seen earlier on this
  expansion path (`ctx.visited`) — a self- or mutually-referential
  struct, not an error — and `:unsupported` when `module` isn't loaded,
  or is loaded but is neither a struct nor an Ecto schema. Callers decide
  what to do with each: `Claudex.Tool.Schema` falls back to an
  unconstrained schema for `:cycle` and raises `Claudex.Tool.SchemaError`
  for `:unsupported`.
  """
  @spec expand(module(), Schema.context()) :: :cycle | {:ok, map()} | :unsupported
  def expand(module, ctx) do
    cond do
      module in ctx.visited -> :cycle
      not Code.ensure_loaded?(module) -> :unsupported
      ecto_schema?(module) -> {:ok, ecto_object(module, visit(ctx, module))}
      struct?(module) -> {:ok, struct_object(module, visit(ctx, module))}
      true -> :unsupported
    end
  end

  @spec visit(Schema.context(), module()) :: Schema.context()
  defp visit(ctx, module), do: %{ctx | visited: [module | ctx.visited], current_module: module}

  defp ecto_schema?(module), do: function_exported?(module, :__schema__, 1)
  defp struct?(module), do: function_exported?(module, :__struct__, 0)

  defp ecto_object(module, ctx) do
    properties =
      Map.new(module.__schema__(:fields), fn field ->
        {Atom.to_string(field), ecto_type_schema(module.__schema__(:type, field), ctx)}
      end)

    object(properties, [])
  end

  # Every object Claudex builds here comes from a known, closed set of
  # fields, so extra properties are always disallowed — same reasoning as
  # the top-level input_schema in Claudex.Tool, and what a tool declared
  # `strict: true` needs at every level, not just the outer one.
  defp object(properties, required) do
    %{type: "object", properties: properties, required: required, additionalProperties: false}
  end

  defp ecto_type_schema(:id, _ctx), do: %{type: "integer"}
  defp ecto_type_schema(:binary_id, _ctx), do: %{type: "string", format: "uuid"}
  defp ecto_type_schema(:integer, _ctx), do: %{type: "integer"}
  defp ecto_type_schema(:float, _ctx), do: %{type: "number"}
  defp ecto_type_schema(:decimal, _ctx), do: %{type: "string"}
  defp ecto_type_schema(:boolean, _ctx), do: %{type: "boolean"}
  defp ecto_type_schema(:string, _ctx), do: %{type: "string"}
  defp ecto_type_schema(:binary, _ctx), do: %{type: "string"}
  defp ecto_type_schema(:map, _ctx), do: %{type: "object"}
  defp ecto_type_schema(:date, _ctx), do: %{type: "string", format: "date"}
  defp ecto_type_schema(:time, _ctx), do: %{type: "string", format: "time"}
  defp ecto_type_schema(:time_usec, _ctx), do: %{type: "string", format: "time"}

  defp ecto_type_schema(type, _ctx)
       when type in [:naive_datetime, :naive_datetime_usec, :utc_datetime, :utc_datetime_usec],
       do: %{type: "string", format: "date-time"}

  defp ecto_type_schema({:array, inner}, ctx),
    do: %{type: "array", items: ecto_type_schema(inner, ctx)}

  defp ecto_type_schema({:map, inner}, ctx),
    do: %{type: "object", additionalProperties: ecto_type_schema(inner, ctx)}

  defp ecto_type_schema({:parameterized, {Ecto.Enum, %{mappings: mappings}}}, _ctx) do
    %{type: "string", enum: Keyword.values(mappings)}
  end

  defp ecto_type_schema(
         {:parameterized, {Ecto.Embedded, %{cardinality: :one, related: related}}},
         ctx
       ) do
    expand_embed!(related, ctx)
  end

  defp ecto_type_schema(
         {:parameterized, {Ecto.Embedded, %{cardinality: :many, related: related}}},
         ctx
       ) do
    %{type: "array", items: expand_embed!(related, ctx)}
  end

  defp ecto_type_schema(custom_type, ctx) when is_atom(custom_type) do
    if Code.ensure_loaded?(custom_type) and function_exported?(custom_type, :type, 0) do
      ecto_type_schema(custom_type.type(), ctx)
    else
      raise SchemaError,
        message:
          "can't build a JSON schema for the Ecto type `#{inspect(custom_type)}` — it doesn't " <>
            "implement Ecto.Type's type/0 callback. Pass args_schema: in the @tool options to describe it explicitly"
    end
  end

  defp ecto_type_schema(unrecognized, _ctx) do
    raise SchemaError,
      message:
        "can't build a JSON schema for the Ecto type `#{inspect(unrecognized)}` — " <>
          "pass args_schema: in the @tool options to describe it explicitly"
  end

  defp expand_embed!(module, ctx) do
    case expand(module, ctx) do
      :cycle -> %{type: "object"}
      {:ok, schema} -> schema
      :unsupported -> raise_unsupported_embed!(module)
    end
  end

  defp raise_unsupported_embed!(module) do
    raise SchemaError,
      message:
        "can't build a JSON schema for the embedded schema `#{inspect(module)}` — it isn't a " <>
          "loaded Ecto schema. Pass args_schema: in the @tool options to describe it explicitly"
  end

  defp struct_object(module, ctx) do
    case fetch_struct_fields(module) do
      {:ok, fields} -> typed_struct_object(fields, ctx)
      :error -> untyped_struct_object(module)
    end
  end

  defp fetch_struct_fields(module) do
    with {:ok, types} <- Code.Typespec.fetch_types(module),
         {:type, {:t, type_ast, []}} <- Enum.find(types, &match?({:type, {:t, _ast, []}}, &1)),
         {:"::", _, [_name, {:%, _, [^module, {:%{}, _, fields}]}]} <-
           Code.Typespec.type_to_quoted({:t, type_ast, []}) do
      {:ok, fields}
    else
      _other -> :error
    end
  end

  defp typed_struct_object(fields, ctx) do
    properties =
      Map.new(fields, fn {field, type_ast} ->
        {Atom.to_string(field), Schema.type_to_schema(type_ast, ctx)}
      end)

    required =
      fields
      |> Enum.reject(fn {_field, type_ast} -> nullable?(type_ast) end)
      |> Enum.map(fn {field, _type_ast} -> Atom.to_string(field) end)

    object(properties, required)
  end

  defp nullable?(type_ast), do: nil in Schema.flatten_union(type_ast)

  defp untyped_struct_object(module) do
    properties =
      module.__struct__()
      |> Map.from_struct()
      |> Map.new(fn {field, _value} -> {Atom.to_string(field), %{}} end)

    object(properties, [])
  end
end

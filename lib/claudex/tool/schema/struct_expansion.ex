defmodule Claudex.Tool.Schema.StructExpansion do
  @moduledoc false

  # A referenced module that isn't compiled yet is waited for, so a struct from
  # the same project can be expanded while that project compiles.
  #
  # Every field of an object is required, and one that can be nil takes null.
  # Left optional, a field that sorts before a required one in `properties`
  # went unfilled: Claude put its value into the field after it instead (seen
  # live with structured outputs on claude-haiku-4-5).
  #
  # Ecto leaves association fields out of `__schema__(:fields)`, so they are
  # skipped; embeds are data and are expanded. Ecto doesn't expose which fields
  # are `NOT NULL`, so in an Ecto-backed object only the fields its
  # `use Claudex.Schema, required:` names, and embeds_many lists, can't be
  # null.
  #
  # A plain struct with no `@type t` still expands, with every field
  # unconstrained, since the field names alone are more useful to Claude than
  # nothing.

  alias Claudex.Tool.Schema
  alias Claudex.Tool.SchemaError

  @dependencies :claudex_schema_dependencies

  @doc """
  Expands `module` into an object schema.

  Returns `:cycle` when `module` was already seen earlier on this
  expansion path (`ctx.visited`), or when two structs compiling at once
  wait on each other (a self- or mutually-referential struct, not an
  error), and `:unsupported` when `module` doesn't exist, or is neither a
  struct nor an Ecto schema. `Claudex.Tool.Schema` falls back to an
  unconstrained schema for `:cycle` and raises `Claudex.Tool.SchemaError`
  for `:unsupported`.
  """
  @spec expand(module(), Schema.context()) :: :cycle | {:ok, map()} | :unsupported
  def expand(module, ctx) do
    if module in ctx.visited, do: :cycle, else: expand_compiled(module, ctx)
  end

  @doc """
  Builds the object schema for a struct from the fields of its `@type t`,
  as `{field, type_ast}` pairs. `Claudex.Schema` calls this while the struct
  compiles, when the type is still a module attribute.
  """
  @spec typed_object(keyword(Macro.t()), Schema.context()) :: map()
  def typed_object(fields, ctx) do
    properties =
      Map.new(fields, fn {field, type_ast} ->
        {Atom.to_string(field), Schema.type_to_schema(type_ast, ctx)}
      end)

    object(properties, Keyword.keys(fields))
  end

  @doc """
  Returns a `require` for every module expanded while `module` compiled,
  for a context whose `:dependent` is `module`.

  A schema built at compile time is only as current as the modules it was
  built from, and requiring them makes Mix recompile `module` when one of
  them changes.
  """
  @spec requires(module()) :: [Macro.t()]
  def requires(module) do
    for dependency <- module |> Module.get_attribute(@dependencies, []) |> Enum.uniq(),
        dependency != module do
      quote do: require(unquote(dependency))
    end
  end

  defp expand_compiled(module, ctx) do
    case Code.ensure_compiled(module) do
      {:module, ^module} -> expand_loaded(module, ctx)
      {:error, :unavailable} -> :cycle
      {:error, _reason} -> :unsupported
    end
  end

  defp expand_loaded(module, ctx) do
    record(ctx, module)

    cond do
      declared?(module) -> {:ok, module.__json_schema__()}
      ecto_schema?(module) -> {:ok, ecto_object(module, visit(ctx, module))}
      struct?(module) -> {:ok, struct_object(module, visit(ctx, module))}
      true -> :unsupported
    end
  end

  defp record(%{dependent: dependent}, module) do
    if Module.open?(dependent) do
      recorded = Module.get_attribute(dependent, @dependencies, [])
      Module.put_attribute(dependent, @dependencies, [module | recorded])
    end

    :ok
  end

  defp record(_ctx, _module), do: :ok

  defp visit(ctx, module), do: %{ctx | visited: [module | ctx.visited], current_module: module}

  defp declared?(module), do: function_exported?(module, :__json_schema__, 0)

  defp ecto_schema?(module), do: function_exported?(module, :__schema__, 1)
  defp struct?(module), do: function_exported?(module, :__struct__, 0)

  defp ecto_object(module, ctx) do
    filled = ecto_required(module)

    properties =
      Map.new(module.__schema__(:fields), fn field ->
        type = module.__schema__(:type, field)
        schema = ecto_type_schema(type, ctx)

        {Atom.to_string(field),
         if(null?(field, type, filled), do: nullable(schema), else: schema)}
      end)

    object(properties, module.__schema__(:fields))
  end

  defp ecto_required(module) do
    if function_exported?(module, :__json_required__, 0),
      do: module.__json_required__(),
      else: []
  end

  # `cast_embed/3` rejects a nil embeds_many, and `[]` says the same thing.
  defp null?(_field, {:parameterized, {Ecto.Embedded, %{cardinality: :many}}}, _filled),
    do: false

  defp null?(field, _type, filled), do: field not in filled

  defp nullable(schema), do: %{anyOf: [schema, %{type: "null"}]}

  # Every object Claudex builds here comes from a known, closed set of
  # fields, so extra properties are always disallowed — same reasoning as
  # the top-level input_schema in Claudex.Tool, and what a tool declared
  # `strict: true` needs at every level, not just the outer one.
  defp object(properties, fields) do
    %{
      type: "object",
      properties: properties,
      required: Enum.map(fields, &Atom.to_string/1),
      additionalProperties: false
    }
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
            "implement Ecto.Type's type/0 callback. " <> Schema.escape_hatch(ctx)
    end
  end

  defp ecto_type_schema(unrecognized, ctx) do
    raise SchemaError,
      message:
        "can't build a JSON schema for the Ecto type `#{inspect(unrecognized)}` — " <>
          Schema.escape_hatch(ctx)
  end

  defp expand_embed!(module, ctx) do
    case expand(module, ctx) do
      :cycle -> %{type: "object"}
      {:ok, schema} -> schema
      :unsupported -> raise_unsupported_embed!(module, ctx)
    end
  end

  defp raise_unsupported_embed!(module, ctx) do
    raise SchemaError,
      message:
        "can't build a JSON schema for the embedded schema `#{inspect(module)}` — it isn't a " <>
          "loaded Ecto schema. " <> Schema.escape_hatch(ctx)
  end

  defp struct_object(module, ctx) do
    case fetch_struct_fields(module) do
      {:ok, fields} -> typed_object(fields, ctx)
      :untyped -> untyped_struct_object(module)
      :unreadable -> raise SchemaError, message: unreadable_message(module)
    end
  end

  defp fetch_struct_fields(module) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} -> struct_fields(module, types)
      :error -> :unreadable
    end
  end

  defp struct_fields(module, types) do
    with {:type, {:t, type_ast, []}} <- Enum.find(types, &match?({:type, {:t, _ast, []}}, &1)),
         {:"::", _, [_name, {:%, _, [^module, {:%{}, _, fields}]}]} <-
           Code.Typespec.type_to_quoted({:t, type_ast, []}) do
      {:ok, fields}
    else
      _no_struct_type -> :untyped
    end
  end

  defp unreadable_message(module) do
    "can't read `#{inspect(module)}`'s `@type t`: it is compiled in the same build as the " <>
      "code reading it, or `mix release` stripped its typespecs. Add `use Claudex.Schema` " <>
      "to `#{inspect(module)}` so its schema is built while it compiles"
  end

  defp untyped_struct_object(module) do
    fields = Enum.map(module.__info__(:struct), & &1.field)

    object(Map.new(fields, &{Atom.to_string(&1), %{}}), fields)
  end
end

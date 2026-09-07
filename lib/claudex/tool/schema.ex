defmodule Claudex.Tool.Schema do
  @moduledoc """
  Turns a function's arguments and its `@spec` into JSON schema properties,
  in the shape the Messages API expects for a tool's `input_schema`.

  This is pure AST-to-schema mapping with no macro magic, kept separate
  from `Claudex.Tool` so the type inference can be tested on its own. A
  `Mod.t()` reference that isn't one of the built-in types (`String.t()`,
  `DateTime.t()`, ...) is handed to `Claudex.Tool.Schema.StructExpansion`,
  which expands it into a nested object when `Mod` is a struct or an Ecto
  schema.

  A typespec construct that can't be mapped raises
  `Claudex.Tool.SchemaError` — see `build/4`.
  """

  alias Claudex.Tool.Schema.StructExpansion
  alias Claudex.Tool.SchemaError

  @typedoc "A function parameter: its name and whether it has a default value."
  @type param :: {name :: String.t(), has_default :: boolean()}

  @typedoc """
  Threaded through every recursive call:

    * `env` — the compile-time environment, needed to resolve an aliased
      module reference (e.g. `Ticket.t()` after `alias My.App.Ticket`) into
      its real module name
    * `visited` — struct modules already being expanded on the current
      path, so a self- or mutually-referential struct stops instead of
      recursing forever
    * `current_module` — which module a *bare* `t()` (no module prefix)
      refers to right now. A struct's own `@type t` can reference itself
      as plain `t()`, not `Mod.t()` — this is how that resolves
  """
  @type context :: %{visited: [module()], env: Macro.Env.t(), current_module: module()}

  @unspecified :__claudex_unspecified_type__

  # Elixir's zero-arity built-in types and the JSON schema each becomes. The
  # clauses matching them are generated below, so adding a type is one line.
  @builtin_types %{
    any: %{},
    atom: %{type: "string"},
    binary: %{type: "string"},
    bitstring: %{type: "string"},
    boolean: %{type: "boolean"},
    charlist: %{type: "array", items: %{type: "integer"}},
    float: %{type: "number"},
    integer: %{type: "integer"},
    iodata: %{type: "string"},
    iolist: %{type: "string"},
    keyword: %{type: "object"},
    list: %{type: "array"},
    map: %{type: "object"},
    non_neg_integer: %{type: "integer", minimum: 0},
    nonempty_list: %{type: "array", minItems: 1},
    number: %{type: "number"},
    pos_integer: %{type: "integer", minimum: 1},
    struct: %{type: "object"},
    term: %{}
  }

  # Stdlib structs the API expects as strings; anything else goes to
  # StructExpansion.
  @remote_types %{
    Date => %{type: "string", format: "date"},
    DateTime => %{type: "string", format: "date-time"},
    NaiveDateTime => %{type: "string", format: "date-time"},
    String => %{type: "string"},
    Time => %{type: "string", format: "time"}
  }

  @doc """
  Extracts each parameter's name and whether it has a default value, from
  the argument AST alone — no `@spec` involved, so this never raises.
  `Claudex.Tool` uses this on its own when a tool is registered with an
  explicit `args_schema:`, since that skips `@spec` inspection entirely.
  """
  @spec params([Macro.t()]) :: [param()]
  def params(args), do: Enum.map(args, &param_info/1)

  @doc """
  Builds the `input_schema` properties for a function, given its argument
  AST (as `@on_definition` receives it), the raw `@spec` entries
  accumulated on the module so far, and the compile-time `env` (used to
  resolve aliased struct references in the spec).

  Also returns the parameter list in call order — the JSON schema alone
  doesn't preserve it once `properties` becomes a map, and `Claudex.Tool`
  needs the order later to dispatch tool calls correctly.

  A parameter with no matching `@spec` at all gets an unconstrained
  (`%{}`) property. A parameter whose `@spec` type Claudex can't map — an
  unsupported typespec construct, or a `Mod.t()` that isn't a loaded struct
  or Ecto schema — raises `Claudex.Tool.SchemaError`. Fix the spec, or pass
  `args_schema:` for that tool.
  """

  @spec build(atom(), [Macro.t()], [tuple()], Macro.Env.t()) :: %{
          properties: map(),
          params: [param()]
        }

  def build(name, args, module_specs, env) do
    param_list = params(args)
    arg_types = spec_arg_types(name, length(param_list), module_specs)
    ctx = new_context(env)

    properties =
      param_list
      |> Enum.zip(pad(arg_types, length(param_list)))
      |> Map.new(fn {{param_name, _has_default}, type_ast} ->
        {param_name, type_to_schema(type_ast, ctx)}
      end)

    %{properties: properties, params: param_list}
  end

  # Public so Claudex.Tool.Schema.StructExpansion can recurse back into it
  # for a struct's own field types.
  @doc false
  @spec type_to_schema(Macro.t(), context()) :: map()
  def type_to_schema(@unspecified, _ctx), do: %{}

  def type_to_schema(nil, _ctx), do: %{type: "null"}

  def type_to_schema(true, _ctx), do: %{const: true}

  def type_to_schema(false, _ctx), do: %{const: false}

  def type_to_schema(literal, _ctx)
      when is_integer(literal) or is_float(literal) or is_binary(literal),
      do: %{const: literal}

  def type_to_schema(literal, _ctx) when is_atom(literal), do: %{const: Atom.to_string(literal)}

  for {name, schema} <- @builtin_types do
    def type_to_schema({unquote(name), _meta, []}, _ctx), do: unquote(Macro.escape(schema))
  end

  def type_to_schema({:%{}, _, _}, _ctx), do: %{type: "object"}

  def type_to_schema({{:., _, [mod_ref, :t]}, _, _}, ctx) do
    remote_type_schema(module_ref(mod_ref, ctx.env), ctx)
  end

  # A struct's own @type t referencing itself is written bare (`t()`),
  # not `Mod.t()` — resolve it against ctx.current_module instead.
  def type_to_schema({:t, _, []}, ctx), do: remote_type_schema(ctx.current_module, ctx)

  def type_to_schema({:list, _, [inner]}, ctx),
    do: %{type: "array", items: type_to_schema(inner, ctx)}

  def type_to_schema([inner], ctx), do: %{type: "array", items: type_to_schema(inner, ctx)}

  def type_to_schema({:|, _, _} = union, ctx) do
    members = flatten_union(union)

    case enum_of(members) do
      {:ok, json_type, values} -> %{type: json_type, enum: values}
      :error -> %{anyOf: Enum.map(members, &type_to_schema(&1, ctx))}
    end
  end

  def type_to_schema(unknown, _ctx) do
    raise SchemaError,
      message:
        "can't build a JSON schema for type `#{Macro.to_string(unknown)}` — " <>
          "pass args_schema: in the @tool options to describe it explicitly"
  end

  # Flattens a right-associated `|` union AST into its member list — `a | b
  # | c` becomes `[a, b, c]`; a non-union node comes back as `[node]`.
  # Exposed for StructExpansion, which reuses it to check whether a
  # struct field's type includes `nil` (and is therefore optional).
  @doc false
  @spec flatten_union(Macro.t()) :: [Macro.t()]
  def flatten_union({:|, _, [left, right]}), do: flatten_union(left) ++ flatten_union(right)

  def flatten_union(other), do: [other]

  defp param_info({:\\, _meta, [pattern, _default]}), do: {param_name(pattern), true}

  defp param_info(pattern), do: {param_name(pattern), false}

  # `def read(_path)` would otherwise publish a property literally named
  # "_path", which Claude never sends.
  defp param_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    name |> Atom.to_string() |> String.trim_leading("_")
  end

  defp param_name(_pattern), do: "arg"

  defp spec_arg_types(name, arity, module_specs) do
    Enum.find_value(module_specs, [], fn
      {:spec, {:"::", _, [{^name, _, arg_types}, _return]}, _meta}
      when is_list(arg_types) and length(arg_types) == arity ->
        arg_types

      _other ->
        nil
    end)
  end

  defp pad(list, size), do: list ++ List.duplicate(@unspecified, max(size - length(list), 0))

  defp new_context(env), do: %{visited: [], env: env, current_module: env.module}

  defp module_ref({:__aliases__, _, _} = alias_ast, env), do: Macro.expand(alias_ast, env)

  defp module_ref(mod, _env) when is_atom(mod), do: mod

  for {module, schema} <- @remote_types do
    defp remote_type_schema(unquote(module), _ctx), do: unquote(Macro.escape(schema))
  end

  defp remote_type_schema(module, ctx) do
    case StructExpansion.expand(module, ctx) do
      :cycle -> %{}
      {:ok, schema} -> schema
      :unsupported -> raise_unsupported_module!(module)
    end
  end

  defp raise_unsupported_module!(module) do
    raise SchemaError,
      message:
        "can't build a JSON schema for `#{inspect(module)}.t()` — it isn't a loaded struct " <>
          "or an Ecto schema. Pass args_schema: in the @tool options to describe it explicitly"
  end

  defp enum_of(members) do
    values = Enum.map(members, &literal_value/1)

    if Enum.all?(values, &match?({:ok, _}, &1)) do
      values |> Enum.map(fn {:ok, value} -> value end) |> collapse_to_enum()
    else
      :error
    end
  end

  defp collapse_to_enum(values) do
    case values |> Enum.map(&json_type_of/1) |> Enum.uniq() do
      [single_type] -> {:ok, single_type, values}
      _mixed -> :error
    end
  end

  defp literal_value(v) when is_boolean(v), do: {:ok, v}

  defp literal_value(v) when is_integer(v) or is_float(v) or is_binary(v), do: {:ok, v}

  defp literal_value(v) when is_atom(v) and not is_nil(v), do: {:ok, Atom.to_string(v)}

  defp literal_value(_v), do: :error

  defp json_type_of(v) when is_boolean(v), do: "boolean"

  defp json_type_of(v) when is_integer(v), do: "integer"

  defp json_type_of(v) when is_float(v), do: "number"

  defp json_type_of(v) when is_binary(v), do: "string"
end

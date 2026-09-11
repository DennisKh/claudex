defmodule Claudex.OutputFormat do
  @moduledoc """
  Builds `output_config.format` from a struct, so Claude answers with JSON in
  that struct's shape.

      Claudex.Messages.create(client, %{
        model: "claude-opus-5",
        max_tokens: 1024,
        output_config: %{format: MyApp.Ticket},
        messages: [Claudex.Message.user("File a ticket for this thread")]
      })

  The schema comes from the struct's `@type t`, the same way `:tools` reads a
  function's `@spec`, so `Claudex.Messages.create/2` takes the module itself.
  The reply is JSON text, which `Claudex.Message.text/1` returns for decoding.
  A reply cut short by `max_tokens`, or a refusal, is not the promised shape,
  so `stop_reason` says whether there is anything to decode.

  The API takes a subset of JSON Schema, and this fits the struct's schema to
  it: every object is closed with `additionalProperties: false`, and whatever
  the subset rejects, such as the `minimum: 0` that a `non_neg_integer()` field
  implies, moves into that property's description, where the model still reads
  it.

  ## What a field's type becomes

  | `@type t` field                                | schema                                   |
  | ---------------------------------------------- | ---------------------------------------- |
  | `String.t()`, `binary()`, `atom()`             | `string`                                 |
  | `integer()`, `float()`, `boolean()`            | `integer`, `number`, `boolean`           |
  | `non_neg_integer()`, `pos_integer()`           | `integer`, the minimum in `description`  |
  | `Date.t()`, `Time.t()`, `DateTime.t()`         | `string` with `format`                   |
  | `:urgent`                                      | `const: "urgent"`                        |
  | a union of atom literals                       | `string` with `enum`                     |
  | a union of number literals                     | `integer` with `enum`                    |
  | a union with `nil`                             | `anyOf` with `null`, and not required    |
  | `list(String.t())`, `[String.t()]`             | `array` of `string`                      |
  | `nonempty_list(String.t())`                    | the same, with `minItems: 1`             |
  | `list()`                                       | `array`, elements unconstrained          |
  | `charlist()`                                   | `array` of `integer`                     |
  | `Reporter.t()`                                 | the struct's own object, nested          |
  | `map()`, `keyword()`, `%{String.t() => t()}`   | an object with no keys: only `{}` fits   |
  | `any()`, `term()`, `{String.t(), integer()}`   | raises `Claudex.Tool.SchemaError`        |

  The unions, written out:

      @type t :: %__MODULE__{
              priority: :low | :medium | :high,
              attempts: 1 | 2 | 3,
              due: Date.t() | nil
            }

  A required field is one whose type doesn't include `nil`. An Ecto schema is
  read through its own reflection instead, and Ecto doesn't say which fields
  are `NOT NULL`, so nothing in one is ever required.

  A `map()` field has no keys to declare, and the API takes an object only with
  its keys named, so the model can fill it with `{}` and nothing else. A struct
  type describes it; a list of key/value structs carries it when the keys
  really are open. `any()` and a tuple have no JSON shape at all, and neither
  does a struct that refers to itself, since the schema is inlined rather than
  referenced.
  """

  alias Claudex.Tool.Schema.StructExpansion
  alias Claudex.Tool.SchemaError

  @string_formats ~w(date-time time date duration email hostname uri ipv4 ipv6 uuid)
  @carried [:enum, :const, :description, :title]

  @doc """
  Returns the `output_config.format` value for a struct module.

      Claudex.OutputFormat.json_schema(MyApp.Ticket)
      #=> %{type: "json_schema", schema: %{type: "object", ...}}

  Raises `Claudex.Tool.SchemaError` when a field has no shape the API can be
  told about.
  """
  @spec json_schema(module()) :: map()
  def json_schema(module) when is_atom(module) do
    %{type: "json_schema", schema: module |> expand() |> strict([])}
  end

  defp expand(module) do
    readable!(module)

    context = %{
      visited: [],
      env: __ENV__,
      current_module: module,
      escape_hatch:
        "Give the field a type the API can be told about, or pass " <>
          "output_config.format yourself"
    }

    case StructExpansion.expand(module, context) do
      {:ok, schema} ->
        schema

      _cycle_or_unsupported ->
        raise SchemaError,
          message:
            "can't build an output format for `#{inspect(module)}` — it isn't a loaded " <>
              "struct or an Ecto schema"
    end
  end

  # A struct's schema is read from its compiled typespec, which `mix release`
  # strips unless told not to. Without this the fields all come back untyped
  # and the failure reads as a modelling mistake.
  defp readable!(module) do
    struct? = Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0)
    ecto? = function_exported?(module, :__schema__, 1)

    if struct? and not ecto? and not declares_t?(module) do
      raise SchemaError,
        message:
          "can't read `#{inspect(module)}`'s `@type t`. An output format is built from it, " <>
            "and this module either doesn't declare one or was compiled without typespecs: " <>
            "`mix release` strips them unless it is given `strip_beams: [keep: [\"Dbgi\"]]`. " <>
            "Build the schema where the types are readable instead: " <>
            "`@format Claudex.OutputFormat.json_schema(#{inspect(module)})`"
    end
  end

  defp declares_t?(module) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} -> Enum.any?(types, &match?({:type, {:t, _ast, []}}, &1))
      :error -> false
    end
  end

  defp strict(schema, path) do
    {kept, used} = supported(schema, path)
    kept = Map.merge(kept, Map.take(schema, @carried))

    if kept == %{}, do: raise(SchemaError, message: unexpressible(path))

    describe(kept, Map.drop(schema, used ++ @carried))
  end

  defp supported(%{anyOf: variants}, path) do
    {%{anyOf: Enum.map(variants, &strict(&1, path))}, [:anyOf]}
  end

  defp supported(%{type: "object"} = schema, path) do
    properties =
      for {name, property} <- Map.get(schema, :properties, %{}),
          into: %{},
          do: {name, strict(property, path ++ [name])}

    object = %{type: "object", properties: properties, additionalProperties: false}

    object =
      case schema do
        %{required: required} -> Map.put(object, :required, required)
        _no_required -> object
      end

    # An Ecto `{:map, inner}` field carries its value schema here, and the API
    # takes only `false`, so leaving it unused sends it to the description.
    used =
      case schema do
        %{additionalProperties: value} when is_map(value) -> [:type, :properties, :required]
        _closed -> [:type, :properties, :additionalProperties, :required]
      end

    {object, used}
  end

  defp supported(%{type: "array"} = schema, path) do
    array =
      case schema do
        %{items: items} -> %{type: "array", items: strict(items, path)}
        _no_items -> %{type: "array"}
      end

    # 0 and 1 are the only counts the API takes, and 1 is what a
    # nonempty_list() implies.
    case schema do
      %{minItems: count} when count in [0, 1] ->
        {Map.put(array, :minItems, count), [:type, :items, :minItems]}

      _other_count ->
        {array, [:type, :items]}
    end
  end

  defp supported(%{type: "string"} = schema, _path) do
    case schema do
      %{format: format} when format in @string_formats ->
        {%{type: "string", format: format}, [:type, :format]}

      _unsupported_format ->
        {%{type: "string"}, [:type]}
    end
  end

  defp supported(%{type: type}, _path), do: {%{type: type}, [:type]}

  defp supported(_schema, _path), do: {%{}, []}

  defp describe(kept, unsupported) when unsupported == %{}, do: kept

  defp describe(kept, unsupported) do
    hints = Enum.map_join(unsupported, ", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)

    Map.update(kept, :description, "{#{hints}}", &(&1 <> "\n\n{#{hints}}"))
  end

  defp unexpressible([]), do: "this struct has no type the API can be told about"

  defp unexpressible(path) do
    "`#{Enum.join(path, ".")}` has no type the API can be told about. An output format " <>
      "needs a concrete type for every field, and `any()`, `term()` and a struct that " <>
      "refers to itself have none"
  end
end

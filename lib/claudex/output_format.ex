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
  The struct declares `use Claudex.Schema`, which builds that schema while
  it compiles:

      defmodule MyApp.Ticket do
        use Claudex.Schema

        defstruct [:title, :priority, :due]

        @type t :: %__MODULE__{
                title: String.t(),
                priority: :low | :high,
                due: Date.t() | nil
              }
      end

  Without it, the first request in a release raises
  `Claudex.Tool.SchemaError`. An Ecto schema doesn't need it except to name
  its required fields, and `Claudex.Schema` says when a struct does.

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

  A required field is one whose type doesn't include `nil`. In an Ecto
  schema, a required field is one named by
  `use Claudex.Schema, required: [...]`, and without that list nothing in
  one is required. See `Claudex.Schema`.

  A `map()` field has no keys to declare, and the API takes an object only with
  its keys named, so the model can fill it with `{}` and nothing else. A struct
  type describes it; a list of key/value structs carries it when the keys
  really are open. `any()` and a tuple have no JSON shape at all, and neither
  does a struct that refers to itself, since the schema is inlined rather than
  referenced.
  """

  alias Claudex.Tool.Schema.{Strict, StructExpansion}
  alias Claudex.Tool.SchemaError

  @unexpressible "An output format needs a concrete type for every field, and `any()`, " <>
                   "`term()` and a struct that refers to itself have none"

  @doc """
  Returns the `output_config.format` value for a struct module.

      Claudex.OutputFormat.json_schema(MyApp.Ticket)
      #=> %{type: "json_schema", schema: %{type: "object", ...}}

  Raises `Claudex.Tool.SchemaError` when a field has no shape the API can be
  told about.
  """
  @spec json_schema(module()) :: map()
  def json_schema(module) when is_atom(module) do
    %{type: "json_schema", schema: module |> expand() |> Strict.fit(@unexpressible)}
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

  # A struct whose types can be read but hold no @type t would otherwise
  # expand with every field unconstrained, which no output format can carry.
  defp readable!(module) do
    if untyped_struct?(module) do
      raise SchemaError,
        message:
          "can't build an output format from `#{inspect(module)}`: it declares no `@type t`. " <>
            "Add `@type t :: %__MODULE__{...}` and `use Claudex.Schema` to it"
    end
  end

  defp untyped_struct?(module) do
    Code.ensure_compiled(module) == {:module, module} and
      function_exported?(module, :__struct__, 0) and
      not function_exported?(module, :__json_schema__, 0) and
      not function_exported?(module, :__schema__, 1) and
      not declares_t?(module)
  end

  # Unreadable types count as declared here: StructExpansion raises for those
  # with the message that names the fix.
  defp declares_t?(module) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} -> Enum.any?(types, &match?({:type, {:t, _ast, []}}, &1))
      :error -> true
    end
  end
end

defmodule Claudex.Schema do
  @moduledoc """
  Builds a struct's JSON schema while the struct compiles, so `@tool` and
  `Claudex.OutputFormat` can use it from anywhere in your app and in a
  release.

      defmodule MyApp.Reporter do
        use Claudex.Schema

        defstruct [:name, :email]
        @type t :: %__MODULE__{name: String.t(), email: String.t() | nil}
      end

      defmodule MyApp.Ticket do
        use Claudex.Schema

        defstruct [:title, :priority, :reporter]

        @type t :: %__MODULE__{
                title: String.t(),
                priority: :low | :high,
                reporter: MyApp.Reporter.t()
              }
      end

  With the line in both, a tool can take a ticket and an output format can
  be built from one, with nothing else to change:

      defmodule MyApp.Tools do
        use Claudex.Tool

        @doc "Files a ticket."
        @tool true
        @spec file_ticket(MyApp.Ticket.t()) :: String.t()
        def file_ticket(ticket), do: ...
      end

      Claudex.Messages.create(client, %{
        model: "claude-opus-5",
        max_tokens: 1024,
        output_config: %{format: MyApp.Ticket},
        messages: [Claudex.Message.user("File a ticket for this thread")]
      })

  The schema comes from `@type t`, read the same way `@tool` reads a
  `@spec`. `Claudex.OutputFormat` lists what each field type becomes.

  ## When a struct needs it

  Add it to every struct of your own app that a `@tool` spec or an
  `output_config.format` names, and to every struct of your app nested
  inside one of those, such as `MyApp.Reporter` above. When the two share
  a file, the nested struct comes first.

  Without it, `Claudex.Tool.SchemaError` names the struct to add it to:

    * at compile time, when the struct is compiled in the same build as the
      tool, or the module attribute, that builds a schema from it. That is
      every clean build of your app.
    * on the first request in a release, when the struct is an output
      format

  A struct from a dependency doesn't need it in a `@tool`. As an output
  format in a release it does, and only the dependency can add it, so
  give the release `strip_beams: [keep: ["Dbgi"]]` instead.

  ## Ecto schemas

  An Ecto schema doesn't need `use Claudex.Schema` for its fields. Ecto
  doesn't say which of them must be filled, though, so on its own every
  field is optional, and the schema lets a tool call or a structured output
  leave any of them out. `required:` names the ones that must be there:

      defmodule MyApp.Edit do
        use Ecto.Schema
        use Claudex.Schema, required: [:old_string, :new_string]

        embedded_schema do
          field :old_string, :string
          field :new_string, :string
          field :replace_all, :boolean
        end
      end

  A name that isn't a field of the schema fails the build. `required:` is
  only for an Ecto schema, and an Ecto schema takes `use Claudex.Schema`
  only with it.
  """

  alias Claudex.Tool.Schema.StructExpansion
  alias Claudex.Tool.SchemaError

  @escape_hatch "Give the field a type the API can be told about"

  @doc false
  defmacro __using__(opts) do
    required = required_option!(opts, __CALLER__.module)

    quote do
      @claudex_schema_required unquote(required)
      @before_compile Claudex.Schema
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    module = env.module
    required = Module.get_attribute(module, :claudex_schema_required)

    ensure_struct!(module)

    if Module.defines?(module, {:__schema__, 1}),
      do: ecto_required(module, required),
      else: struct_schema(env, required)
  end

  @doc false
  @spec __after_verify__(module()) :: :ok
  def __after_verify__(module) do
    case module.__json_required__() -- module.__schema__(:fields) do
      [] ->
        :ok

      unknown ->
        raise SchemaError,
          message:
            "`use Claudex.Schema, required:` in `#{inspect(module)}` names " <>
              "#{Enum.map_join(unknown, ", ", &inspect/1)}, which isn't a field of the schema"
    end
  end

  defp required_option!(opts, module) do
    case opts do
      [] ->
        nil

      [required: names] when is_list(names) and names != [] ->
        if Enum.all?(names, &is_atom/1), do: names, else: raise_option!(module)

      _other ->
        raise_option!(module)
    end
  end

  defp raise_option!(module) do
    raise SchemaError,
      message:
        "`use Claudex.Schema` in `#{inspect(module)}` takes only `required:`, a list of " <>
          "field names"
  end

  defp ecto_required(module, nil) do
    raise SchemaError,
      message:
        "`#{inspect(module)}` is an Ecto schema, which doesn't need `use Claudex.Schema` " <>
          "unless it names required fields: `use Claudex.Schema, required: [...]`"
  end

  defp ecto_required(_module, required) do
    quote do
      @after_verify Claudex.Schema

      @doc false
      @spec __json_required__() :: [atom()]
      def __json_required__, do: unquote(required)
    end
  end

  defp struct_schema(env, nil) do
    context = %{
      visited: [env.module],
      env: env,
      current_module: env.module,
      dependent: env.module,
      escape_hatch: @escape_hatch
    }

    schema = env.module |> struct_fields!() |> StructExpansion.typed_object(context)

    quote do
      unquote_splicing(StructExpansion.requires(env.module))

      @doc false
      @spec __json_schema__() :: map()
      def __json_schema__, do: unquote(Macro.escape(schema))
    end
  end

  defp struct_schema(env, _required) do
    raise SchemaError,
      message:
        "`use Claudex.Schema, required:` in `#{inspect(env.module)}` is for an Ecto schema. " <>
          "A struct's `@type t` decides which fields are required: a field whose type " <>
          "includes `nil` is optional"
  end

  defp struct_fields!(module) do
    case Enum.find_value(Module.get_attribute(module, :type), &struct_fields/1) do
      nil -> raise SchemaError, message: missing_type_message(module)
      fields -> fields
    end
  end

  defp ensure_struct!(module) do
    if not Module.defines?(module, {:__struct__, 0}) do
      raise SchemaError,
        message:
          "`use Claudex.Schema` in `#{inspect(module)}` needs a struct, but it has no " <>
            "`defstruct`"
    end
  end

  defp struct_fields({:type, {:"::", _, [{:t, _, args}, {:%, _, [_name, {:%{}, _, fields}]}]}, _})
       when args in [nil, []],
       do: fields

  defp struct_fields(_type), do: nil

  defp missing_type_message(module) do
    "`use Claudex.Schema` in `#{inspect(module)}` builds the schema from " <>
      "`@type t :: %__MODULE__{...}`, and the module declares none"
  end
end

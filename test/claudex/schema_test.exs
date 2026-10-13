defmodule Claudex.SchemaTest do
  @moduledoc """
  `Code.compile_string/1` writes no `.beam`, so a module compiled through it
  has no typespecs anyone can read: the state a struct is in while the rest
  of its build compiles, and the state `mix release` leaves it in.
  """

  use ExUnit.Case, async: true

  alias Claudex.OutputFormat
  alias Claudex.Tool.SchemaError

  defp compile(source) do
    prefix = "Claudex.SchemaTest.M#{System.unique_integer([:positive])}"
    source |> String.replace("PREFIX", prefix) |> Code.compile_string()
    prefix
  end

  defp module(prefix, name), do: Module.concat([prefix, name])

  defp parallel_compile(dir, prefix, sources) do
    sources
    |> Enum.with_index()
    |> Enum.map(fn {source, index} ->
      path = Path.join(dir, "#{index}.ex")
      File.write!(path, String.replace(source, "PREFIX", prefix))
      path
    end)
    |> Kernel.ParallelCompiler.compile(return_diagnostics: true)
  end

  @reporter """
  defmodule PREFIX.Reporter do
    use Claudex.Schema

    defstruct [:name, :email]
    @type t :: %__MODULE__{name: String.t(), email: String.t() | nil}
  end
  """

  @ticket """
  defmodule PREFIX.Ticket do
    use Claudex.Schema

    alias PREFIX.Reporter

    defstruct [:title, :count, :reporter]

    @type t :: %__MODULE__{
            title: String.t(),
            count: non_neg_integer(),
            reporter: Reporter.t()
          }
  end
  """

  test "a struct builds its schema from @type t while it compiles" do
    prefix = compile(@reporter <> @ticket)

    assert module(prefix, Ticket).__json_schema__() == %{
             type: "object",
             properties: %{
               "title" => %{type: "string"},
               "count" => %{type: "integer", minimum: 0},
               "reporter" => %{
                 type: "object",
                 properties: %{
                   "name" => %{type: "string"},
                   "email" => %{anyOf: [%{type: "string"}, %{type: "null"}]}
                 },
                 required: ["name"],
                 additionalProperties: false
               }
             },
             required: ["title", "count", "reporter"],
             additionalProperties: false
           }
  end

  test "a struct that refers to itself leaves that field unconstrained" do
    prefix =
      compile("""
      defmodule PREFIX.Node do
        use Claudex.Schema

        defstruct [:name, :parent]
        @type t :: %__MODULE__{name: String.t(), parent: __MODULE__.t() | nil}
      end
      """)

    assert module(prefix, Node).__json_schema__().properties["parent"] ==
             %{anyOf: [%{}, %{type: "null"}]}
  end

  test "a tool takes a struct that has no readable .beam" do
    prefix =
      compile(
        @reporter <>
          @ticket <>
          """
          defmodule PREFIX.Tools do
            use Claudex.Tool

            @doc "Files a ticket."
            @tool true
            @spec file(PREFIX.Ticket.t()) :: String.t()
            def file(_ticket), do: "filed"
          end
          """
      )

    [tool] = module(prefix, Tools).__tools__()

    assert tool.input_schema.properties["ticket"] == module(prefix, Ticket).__json_schema__()
  end

  # The tool's file is listed first, so it compiles before the struct exists
  # and has to wait for it, the way a clean build of an app does.
  @tag :tmp_dir
  test "a tool waits for a struct compiling in the same build", %{tmp_dir: tmp_dir} do
    prefix = "Claudex.SchemaTest.M#{System.unique_integer([:positive])}"

    tools = """
    defmodule PREFIX.Tools do
      use Claudex.Tool

      @doc "Files a ticket."
      @tool true
      @spec file(PREFIX.Ticket.t()) :: String.t()
      def file(_ticket), do: "filed"
    end
    """

    {:ok, _modules, _warnings} = parallel_compile(tmp_dir, prefix, [tools, @reporter, @ticket])

    [tool] = module(prefix, Tools).__tools__()

    assert tool.input_schema.properties["ticket"] == module(prefix, Ticket).__json_schema__()
  end

  @tag :tmp_dir
  test "two structs compiling at once that refer to each other leave those fields unconstrained",
       %{tmp_dir: tmp_dir} do
    prefix = "Claudex.SchemaTest.M#{System.unique_integer([:positive])}"

    sources =
      for {name, other} <- [{"Left", "Right"}, {"Right", "Left"}] do
        """
        defmodule PREFIX.#{name} do
          use Claudex.Schema

          defstruct [:other]
          @type t :: %__MODULE__{other: PREFIX.#{other}.t() | nil}
        end
        """
      end

    {:ok, _modules, _warnings} = parallel_compile(tmp_dir, prefix, sources)

    for name <- [Left, Right] do
      assert module(prefix, name).__json_schema__().properties["other"] ==
               %{anyOf: [%{}, %{type: "null"}]}
    end
  end

  test "an output format is built from a struct that has no readable .beam" do
    prefix = compile(@reporter <> @ticket)

    assert %{type: "json_schema", schema: schema} =
             OutputFormat.json_schema(module(prefix, Ticket))

    assert schema.properties["count"] == %{type: "integer", description: "{minimum: 0}"}
  end

  test "a struct with no readable .beam and no use Claudex.Schema names the fix" do
    message =
      ~r/can't read `Claudex\.SchemaTest\.M\d+\.Plain`'s `@type t`.*Add `use Claudex\.Schema` to `Claudex\.SchemaTest\.M\d+\.Plain`/s

    assert_raise SchemaError, message, fn ->
      compile("""
      defmodule PREFIX.Plain do
        defstruct [:title]
        @type t :: %__MODULE__{title: String.t()}
      end

      defmodule PREFIX.Tools do
        use Claudex.Tool

        @doc "Files it."
        @tool true
        @spec file(PREFIX.Plain.t()) :: String.t()
        def file(_plain), do: "filed"
      end
      """)
    end
  end

  test "an output format from a struct with no readable .beam names the fix" do
    prefix =
      compile("""
      defmodule PREFIX.Plain do
        defstruct [:title]
        @type t :: %__MODULE__{title: String.t()}
      end
      """)

    assert_raise SchemaError, ~r/Add `use Claudex\.Schema`/, fn ->
      OutputFormat.json_schema(module(prefix, Plain))
    end
  end

  test "a module with no defstruct can't use it" do
    assert_raise SchemaError, ~r/needs a struct, but it has no `defstruct`/, fn ->
      compile("""
      defmodule PREFIX.NotAStruct do
        use Claudex.Schema
      end
      """)
    end
  end

  test "a struct with no @type t can't use it" do
    assert_raise SchemaError,
                 ~r/`@type t :: %__MODULE__\{...\}`, and the module declares none/,
                 fn ->
                   compile("""
                   defmodule PREFIX.Untyped do
                     use Claudex.Schema

                     defstruct [:title]
                   end
                   """)
                 end
  end

  test "an Ecto schema can't use it" do
    assert_raise SchemaError,
                 ~r/is an Ecto schema, which doesn't need `use Claudex.Schema`/,
                 fn ->
                   compile("""
                   defmodule PREFIX.Post do
                     use Ecto.Schema
                     use Claudex.Schema

                     embedded_schema do
                       field(:title, :string)
                     end

                     @type t :: %__MODULE__{id: String.t() | nil, title: String.t() | nil}
                   end
                   """)
                 end
  end

  @edit """
  defmodule PREFIX.Edit do
    use Ecto.Schema
    use Claudex.Schema, required: [:old_string, :new_string]

    embedded_schema do
      field(:old_string, :string)
      field(:new_string, :string)
      field(:replace_all, :boolean)
    end
  end
  """

  test "an Ecto schema names the fields a tool's caller must fill" do
    prefix =
      compile(
        @edit <>
          """
          defmodule PREFIX.Tools do
            use Claudex.Tool

            @doc "Applies an edit."
            @tool true
            @spec apply_edit(PREFIX.Edit.t()) :: String.t()
            def apply_edit(_edit), do: "applied"
          end
          """
      )

    [tool] = module(prefix, Tools).__tools__()

    assert tool.input_schema.properties["edit"].required == ["old_string", "new_string"]
  end

  test "an Ecto schema's required fields reach its output format" do
    prefix = compile(@edit)

    assert %{schema: %{required: ["old_string", "new_string"]}} =
             OutputFormat.json_schema(module(prefix, Edit))
  end

  # The check runs in the compiler's verifier process after the module is
  # built. That process is linked to the one compiling, so the raise arrives
  # as its exit rather than reaching assert_raise.
  @tag :capture_log
  test "a required name that isn't a field of the Ecto schema fails the build" do
    {_pid, ref} =
      spawn_monitor(fn ->
        compile("""
        defmodule PREFIX.Typo do
          use Ecto.Schema
          use Claudex.Schema, required: [:old_strng]

          embedded_schema do
            field(:old_string, :string)
          end
        end
        """)
      end)

    assert_receive {:DOWN, ^ref, :process, _pid, {%SchemaError{message: message}, _stacktrace}}
    assert message =~ "names :old_strng, which isn't a field of the schema"
  end

  test "a plain struct can't name required fields" do
    assert_raise SchemaError, ~r/required:` in `.*\.Plain` is for an Ecto schema/, fn ->
      compile("""
      defmodule PREFIX.Plain do
        use Claudex.Schema, required: [:title]

        defstruct [:title]
        @type t :: %__MODULE__{title: String.t()}
      end
      """)
    end
  end

  test "required: takes a list of field names and nothing else" do
    for opts <- ["required: :title", "required: []", ~s(required: ["title"]), "strict: true"] do
      assert_raise SchemaError, ~r/takes only `required:`, a list of field names/, fn ->
        compile("""
        defmodule PREFIX.Opts do
          use Ecto.Schema
          use Claudex.Schema, #{opts}

          embedded_schema do
            field(:title, :string)
          end
        end
        """)
      end
    end
  end
end

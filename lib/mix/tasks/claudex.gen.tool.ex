defmodule Mix.Tasks.Claudex.Gen.Tool do
  @shortdoc "Generates a tool function in a Claudex.Tool module"

  @moduledoc """
  Generates a tool function, with the `@doc`, `@tool` and `@spec` a tool needs.

      mix claudex.gen.tool MyApp.Tools read_file path

  That writes `lib/my_app/tools.ex`:

      defmodule MyApp.Tools do
        use Claudex.Tool

        @doc \"""
        One sentence saying what the tool does, in the second person.

        This text is the prompt Claude reads to decide whether to call it.
        \"""
        @tool %{args: [path: "What this argument is, in a sentence."]}
        @spec read_file(String.t()) :: String.t()
        def read_file(path) do
          raise "not implemented"
        end
      end

  Run it again with a different function name and the new tool is appended to
  the same module, so one file holds as many tools as you like.

  Every argument you name gets an `args:` entry, because an argument Claude
  has no description for is the one it passes the wrong value to. The `@doc`
  and those descriptions are placeholders: fill them in before using the
  tool, and write them for Claude rather than for a colleague reading the
  source. The `@spec` types are placeholders too, `String.t()` throughout,
  and they decide the JSON schema Claude is given.

  See `Claudex.Tool` for what each attribute does.
  """

  use Mix.Task

  @doc_placeholder """
  One sentence saying what the tool does, in the second person.

  This text is the prompt Claude reads to decide whether to call it.\
  """

  @arg_placeholder "What this argument is, in a sentence."

  @module_pattern ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  @name_pattern ~r/\A[a-z][A-Za-z0-9_]*\z/

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {module, function, arguments} = parse!(args)
    path = Path.join("lib", Macro.underscore(module) <> ".ex")

    case File.read(path) do
      {:ok, source} -> append(path, source, module, function, arguments)
      {:error, :enoent} -> create(path, module, function, arguments)
      {:error, reason} -> Mix.raise("could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp parse!([module, function | arguments]) do
    validate!(@module_pattern, module, "#{module} is not a module name, try MyApp.Tools")
    validate!(@name_pattern, function, "#{function} is not a function name, try read_file")

    Enum.each(arguments, fn argument ->
      validate!(@name_pattern, argument, "#{argument} is not an argument name, try path")
    end)

    case arguments -- Enum.uniq(arguments) do
      [] -> {Module.concat([module]), function, arguments}
      [duplicate | _] -> Mix.raise("argument #{duplicate} is named twice")
    end
  end

  defp parse!(_args) do
    Mix.raise("""
    expected a module, a function name, and one argument name per argument:

        mix claudex.gen.tool MyApp.Tools read_file path
    """)
  end

  defp validate!(pattern, value, message) do
    unless Regex.match?(pattern, value), do: Mix.raise(message)
  end

  defp create(path, module, function, arguments) do
    source = """
    defmodule #{inspect(module)} do
      use Claudex.Tool

    #{tool_source(function, arguments)}
    end
    """

    Mix.Generator.create_file(path, source)
  end

  defp append(path, source, module, function, arguments) do
    {end_line, body} = module!(source, path, module)

    unless uses_tool?(body) do
      Mix.raise("#{inspect(module)} in #{path} has no `use Claudex.Tool`, add it first")
    end

    if defines?(body, function, length(arguments)) do
      Mix.raise("#{inspect(module)} already defines #{function}/#{length(arguments)}")
    end

    {before, from_end} = source |> String.split("\n") |> Enum.split(end_line - 1)

    appended =
      (trim_trailing_blanks(before) ++ ["", tool_source(function, arguments)] ++ from_end)
      |> Enum.join("\n")

    File.write!(path, appended)
    Mix.shell().info([:green, "* injecting ", :reset, Path.relative_to_cwd(path)])
  end

  defp tool_source(function, arguments) do
    """
    @doc \"""
    #{@doc_placeholder}
    \"""
    #{tool_attribute(arguments)}
    @spec #{function}(#{Enum.map_join(arguments, ", ", fn _argument -> "String.t()" end)}) :: String.t()
    def #{function}#{parameters(arguments)} do
      raise "not implemented"
    end
    """
    |> Code.format_string!(line_length: 96)
    |> IO.iodata_to_binary()
    |> indent()
  end

  defp parameters([]), do: ""

  defp parameters(arguments) do
    "(" <> Enum.map_join(arguments, ", ", &("_" <> &1)) <> ")"
  end

  defp tool_attribute([]), do: "@tool true"

  defp tool_attribute(arguments) do
    descriptions =
      Enum.map_join(arguments, ", ", fn argument ->
        "#{argument}: #{inspect(@arg_placeholder)}"
      end)

    "@tool %{args: [#{descriptions}]}"
  end

  defp indent(source) do
    source
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
    |> String.trim_trailing()
  end

  defp module!(source, path, module) do
    ast =
      case Code.string_to_quoted(source, token_metadata: true, emit_warnings: false) do
        {:ok, ast} -> ast
        {:error, _reason} -> Mix.raise("#{path} does not parse, fix it first")
      end

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, meta, [{:__aliases__, _, parts}, [do: body]]} = node, nil ->
          if Module.concat(parts) == module,
            do: {node, {meta[:end][:line], body}},
            else: {node, nil}

        node, found ->
          {node, found}
      end)

    found || Mix.raise("#{path} holds no #{inspect(module)}")
  end

  defp uses_tool?(body) do
    Enum.any?(
      expressions(body),
      &match?({:use, _, [{:__aliases__, _, [:Claudex, :Tool]} | _]}, &1)
    )
  end

  defp defines?(body, function, arity) do
    name = String.to_atom(function)

    Enum.any?(expressions(body), fn
      {:def, _, [head | _]} -> match_head?(head, name, arity)
      _expression -> false
    end)
  end

  defp match_head?({:when, _, [head | _]}, name, arity), do: match_head?(head, name, arity)

  defp match_head?({name, _, arguments}, name, arity) when is_list(arguments),
    do: length(arguments) == arity

  defp match_head?({name, _, nil}, name, arity), do: arity == 0
  defp match_head?(_head, _name, _arity), do: false

  defp expressions({:__block__, _, expressions}), do: expressions
  defp expressions(expression), do: [expression]

  defp trim_trailing_blanks(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end
end

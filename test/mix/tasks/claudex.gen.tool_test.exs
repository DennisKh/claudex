defmodule Mix.Tasks.Claudex.Gen.ToolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  describe "run/1" do
    test "writes a module holding the first tool", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ~w[MyApp.Tools read_file path])

      source = read(tmp_dir, "lib/my_app/tools.ex")

      assert source =~ "defmodule MyApp.Tools do"
      assert source =~ "use Claudex.Tool"
      assert source =~ ~s(@tool %{args: [path: "What this argument is, in a sentence."]})
      assert source =~ "@spec read_file(String.t()) :: String.t()"
      assert source =~ "def read_file(_path) do"
    end

    test "what it writes compiles and registers as a tool", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ~w[Registered.Tools read_file path])

      module = compile(tmp_dir, "lib/registered/tools.ex")

      assert [tool] = Claudex.Tool.list(module)
      assert tool.name == "read_file"

      assert tool.input_schema.properties == %{
               "path" => %{type: "string", description: "What this argument is, in a sentence."}
             }
    end

    test "appends a second tool to a module it already wrote", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ~w[Appended.Tools read_file path])
      generate(tmp_dir, ~w[Appended.Tools write_file path contents])

      module = compile(tmp_dir, "lib/appended/tools.ex")

      assert module |> Claudex.Tool.list() |> Enum.map(& &1.name) |> Enum.sort() ==
               ["read_file", "write_file"]
    end

    test "a tool with no arguments takes @tool true", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ~w[Nullary.Tools now])

      source = read(tmp_dir, "lib/nullary/tools.ex")

      assert source =~ "@tool true"
      assert source =~ "@spec now() :: String.t()"
      assert source =~ "def now do"
    end

    test "what it writes is already formatted", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ~w[Formatted.Tools read_file path])
      generate(tmp_dir, ~w[Formatted.Tools write_file path contents encoding])

      source = read(tmp_dir, "lib/formatted/tools.ex")

      assert IO.iodata_to_binary([Code.format_string!(source), ?\n]) == source
    end

    test "refuses a function the module already defines", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ~w[Clash.Tools read_file path])

      assert_raise Mix.Error, "Clash.Tools already defines read_file/1", fn ->
        generate(tmp_dir, ~w[Clash.Tools read_file other])
      end
    end

    test "refuses a module that doesn't use Claudex.Tool", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/plain/mod.ex", "defmodule Plain.Mod do\nend\n")

      assert_raise Mix.Error, ~r/has no `use Claudex.Tool`/, fn ->
        generate(tmp_dir, ~w[Plain.Mod now])
      end
    end

    test "refuses a file that holds a different module", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/other/thing.ex", "defmodule Somewhere.Else do\nend\n")

      assert_raise Mix.Error, ~r/holds no Other.Thing/, fn ->
        generate(tmp_dir, ~w[Other.Thing now])
      end
    end

    test "refuses names it can't write", %{tmp_dir: tmp_dir} do
      assert_raise Mix.Error, ~r/is not a module name/, fn ->
        generate(tmp_dir, ~w[myapp read_file])
      end

      assert_raise Mix.Error, ~r/is not a function name/, fn ->
        generate(tmp_dir, ~w[MyApp.Tools ReadFile])
      end

      assert_raise Mix.Error, ~r/is named twice/, fn ->
        generate(tmp_dir, ~w[MyApp.Tools read_file path path])
      end

      assert_raise Mix.Error, ~r/expected a module, a function name/, fn ->
        generate(tmp_dir, ~w[MyApp.Tools])
      end
    end
  end

  defp generate(tmp_dir, args) do
    File.cd!(tmp_dir, fn ->
      capture_io(fn -> Mix.Tasks.Claudex.Gen.Tool.run(args) end)
    end)
  end

  defp read(tmp_dir, path), do: tmp_dir |> Path.join(path) |> File.read!()

  defp write(tmp_dir, path, source) do
    full = Path.join(tmp_dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, source)
  end

  defp compile(tmp_dir, path) do
    [{module, _bytecode} | _rest] = tmp_dir |> read(path) |> Code.compile_string()
    module
  end
end

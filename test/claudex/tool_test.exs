defmodule Claudex.ToolTest do
  use ExUnit.Case, async: true

  alias Claudex.TestSupport.Schemas.{EctoTicket, Ticket}
  alias Claudex.Tool.CallError

  doctest Claudex.Tool

  defmodule AgentTools do
    use Claudex.Tool

    @doc "Adds two numbers. b defaults to 0 if omitted."
    @tool true
    @spec add(number(), number()) :: number()
    def add(a, b \\ 0), do: a + b

    @doc "Calculates list statistics."
    @tool true
    @spec sum_list([non_neg_integer()]) :: integer()
    def sum_list(numbers), do: Enum.sum(numbers)

    @doc "Fetches current weather for a city."
    @tool %{
      args_schema: %{
        "location" => %{type: "string", description: "City and state"},
        "unit" => %{type: "string", enum: ["celsius", "fahrenheit"]}
      },
      strict: true
    }
    @spec get_weather(String.t(), String.t()) :: String.t()
    def get_weather(location, unit \\ "fahrenheit"), do: "Weather for #{location} in #{unit}"

    @spec not_a_tool() :: :ok
    def not_a_tool, do: :ok
  end

  defmodule StructTools do
    use Claudex.Tool

    # The @spec types the argument as a struct, but what actually arrives
    # from a tool_use block is the plain decoded JSON map (string keys) —
    # Claudex doesn't cast it into a real struct for you. Map access here,
    # not dot access, reflects what the function genuinely receives.
    @doc "Summarizes a support ticket (a plain struct type)."
    @tool true
    @spec summarize_ticket(Ticket.t()) :: String.t()
    def summarize_ticket(ticket), do: ticket["subject"]

    @doc "Summarizes a support ticket (an Ecto schema)."
    @tool true
    @spec summarize_ecto_ticket(EctoTicket.t()) :: String.t()
    def summarize_ecto_ticket(ticket), do: ticket["subject"]

    # args_schema: takes priority over @spec — the spec below is bogus
    # (pid() can't be mapped and would normally raise) to prove it's never
    # even inspected once args_schema: is given.
    @doc "A tool whose @spec Claudex can't map, sidestepped via args_schema."
    @tool %{args_schema: %{"note" => %{type: "string"}}}
    @spec ignores_bad_spec(pid()) :: :ok
    def ignores_bad_spec(note), do: note
  end

  test "__tools__/0 only lists @tool-tagged functions" do
    names = AgentTools.__tools__() |> Enum.map(& &1.name)

    assert names == ["add", "sum_list", "get_weather"]
  end

  test "__tools__/0 infers input_schema from @spec and @doc" do
    [add | _] = AgentTools.__tools__()

    assert add.description == "Adds two numbers. b defaults to 0 if omitted."

    assert add.input_schema == %{
             type: "object",
             properties: %{"a" => %{type: "number"}, "b" => %{type: "number"}},
             required: ["a"],
             additionalProperties: false
           }

    refute Map.has_key?(add, :strict)
  end

  test "__tools__/0 honors an explicit args_schema and strict: true" do
    weather = Enum.find(AgentTools.__tools__(), &(&1.name == "get_weather"))

    assert weather.strict == true

    assert weather.input_schema.properties == %{
             "location" => %{type: "string", description: "City and state"},
             "unit" => %{type: "string", enum: ["celsius", "fahrenheit"]}
           }

    assert weather.input_schema.required == ["location"]
  end

  test "__call_tool__/2 runs the matching function with args resolved by name" do
    assert AgentTools.__call_tool__("add", %{"b" => 2, "a" => 1}) == {:ok, 3}
  end

  test "__call_tool__/2 uses the function's default for an omitted optional argument" do
    assert AgentTools.__call_tool__("add", %{"a" => 5}) == {:ok, 5}

    assert AgentTools.__call_tool__("get_weather", %{"location" => "SF"}) ==
             {:ok, "Weather for SF in fahrenheit"}
  end

  test "__call_tool__/2 works with array arguments" do
    assert AgentTools.__call_tool__("sum_list", %{"numbers" => [1, 2, 3]}) == {:ok, 6}
  end

  test "__call_tool__/2 returns an error for an unknown tool" do
    assert {:error, %CallError{type: :unknown_tool}} = AgentTools.__call_tool__("nope", %{})
  end

  test "__tools__/0 expands a struct-typed argument into a nested object schema" do
    [tool] = StructTools.__tools__() |> Enum.filter(&(&1.name == "summarize_ticket"))

    assert %{"ticket" => ticket_schema} = tool.input_schema.properties
    assert ticket_schema.type == "object"

    assert Map.keys(ticket_schema.properties) |> Enum.sort() == [
             "address",
             "id",
             "status",
             "subject"
           ]

    assert Enum.sort(ticket_schema.required) == ["id", "status", "subject"]
  end

  defmodule DecodedTools do
    use Claudex.Tool

    @doc "Echoes a level."
    @tool true
    @spec echo_level(:low | :high) :: term()
    def echo_level(level), do: level

    @doc "Echoes a count, or all."
    @tool true
    @spec echo_count(:all | pos_integer()) :: term()
    def echo_count(count), do: count

    @doc "Echoes a date."
    @tool true
    @spec echo_date(Date.t()) :: term()
    def echo_date(date), do: date

    @doc "Echoes options."
    @tool true
    @spec echo_opts(keyword()) :: term()
    def echo_opts(opts), do: opts
  end

  describe "an argument arrives as Claude sent it" do
    test "for atom literals, as a string" do
      assert DecodedTools.__call_tool__("echo_level", %{"level" => "low"}) == {:ok, "low"}
    end

    test "for a union mixing an atom with another type, as a string" do
      assert DecodedTools.__call_tool__("echo_count", %{"count" => "all"}) == {:ok, "all"}
    end

    test "for a date, as a string" do
      assert DecodedTools.__call_tool__("echo_date", %{"date" => "2026-10-17"}) ==
               {:ok, "2026-10-17"}
    end

    test "for a keyword list, as a map with string keys" do
      assert DecodedTools.__call_tool__("echo_opts", %{"opts" => %{"limit" => 3}}) ==
               {:ok, %{"limit" => 3}}
    end
  end

  test "__tools__/0 expands an Ecto-schema-typed argument into a nested object schema" do
    [tool] = StructTools.__tools__() |> Enum.filter(&(&1.name == "summarize_ecto_ticket"))

    assert %{"ticket" => ticket_schema} = tool.input_schema.properties
    assert ticket_schema.properties["status"] == %{type: "string", enum: ["open", "closed"]}
    refute Map.has_key?(ticket_schema.properties, "comments")
  end

  test "__call_tool__/2 dispatches a struct-typed argument as the decoded JSON map" do
    input = %{"ticket" => %{"id" => 1, "subject" => "Broken printer", "status" => "open"}}

    assert StructTools.__call_tool__("summarize_ticket", input) == {:ok, "Broken printer"}
  end

  test "args_schema: takes priority over @spec — an unmappable spec next to it never raises" do
    [tool] = StructTools.__tools__() |> Enum.filter(&(&1.name == "ignores_bad_spec"))

    assert tool.input_schema.properties == %{"note" => %{type: "string"}}
  end

  test "list/1 expands a single Claudex.Tool module into its tool list" do
    assert Claudex.Tool.list(AgentTools) == AgentTools.__tools__()
  end

  test "list/1 expands a list mixing modules and plain tool maps, preserving order" do
    extra_tool = %{name: "extra", description: "hand-built", input_schema: %{}}

    assert Claudex.Tool.list([extra_tool, AgentTools]) == [extra_tool | AgentTools.__tools__()]
  end

  test "list/1 passes a plain list of tool maps through unchanged" do
    tools = [%{name: "a", description: "", input_schema: %{}}]

    assert Claudex.Tool.list(tools) == tools
  end

  test "list/1 returns an empty list for nil" do
    assert Claudex.Tool.list(nil) == []
  end

  describe "@tool options" do
    defp define(opts, function \\ "@spec a() :: :ok\ndef a, do: :ok") do
      Code.compile_string("""
      defmodule ToolOpts#{System.unique_integer([:positive])} do
        use Claudex.Tool
        @doc "X."
        @tool #{opts}
        #{function}
      end
      """)
    end

    test "an unknown key names itself instead of being ignored" do
      assert_raise Claudex.Tool.SchemaError, ~r/unknown `@tool` option :stirct/, fn ->
        define(~s(%{stirct: true}))
      end
    end

    test ":strict must be a boolean, not merely truthy" do
      assert_raise Claudex.Tool.SchemaError, ~r/:strict must be true or false, got: 0/, fn ->
        define("%{strict: 0}")
      end

      assert_raise Claudex.Tool.SchemaError, ~r/:strict must be true or false/, fn ->
        define(~s(%{strict: "yes"}))
      end
    end

    test "@tool takes true or a map, nothing else" do
      assert_raise Claudex.Tool.SchemaError, ~r/takes true or a map of options, got: :yes/, fn ->
        define(":yes")
      end
    end

    test "two arities of one function can't both be tools, since they share its name" do
      assert_raise Claudex.Tool.SchemaError, ~r/add\/2 and add\/3 .* both the tool "add"/s, fn ->
        Code.compile_string("""
        defmodule TwoArities#{System.unique_integer([:positive])} do
          use Claudex.Tool

          @doc "Adds two."
          @tool true
          @spec add(integer(), integer()) :: integer()
          def add(a, b), do: a + b

          @doc "Adds three."
          @tool true
          @spec add(integer(), integer(), integer()) :: integer()
          def add(a, b, c), do: a + b + c
        end
        """)
      end
    end

    test "@tool on a second clause of the same function says it belongs once" do
      assert_raise Claudex.Tool.SchemaError,
                   ~r/on two clauses of add\/2 .* once, above the first/s,
                   fn ->
                     Code.compile_string("""
                     defmodule TwoClauses#{System.unique_integer([:positive])} do
                       use Claudex.Tool

                       @doc "Adds."
                       @tool true
                       @spec add(integer(), integer()) :: integer()
                       def add(0 = _a, b), do: b

                       @tool true
                       def add(a, b), do: a + b
                     end
                     """)
                   end
    end

    test "a defaulted argument is still one tool" do
      [{module, _bytecode}] =
        Code.compile_string("""
        defmodule Defaulted#{System.unique_integer([:positive])} do
          use Claudex.Tool

          @doc "Adds."
          @tool true
          @spec add(integer(), integer()) :: integer()
          def add(a, b \\\\ 0), do: a + b
        end
        """)

      assert [%{name: "add"}] = Claudex.Tool.list(module)
    end

    for name <- ["valid?", "run!", "café", String.duplicate("a", 129)] do
      test "a function named #{String.slice(name, 0, 12)} (#{String.length(name)} chars) can't be a tool" do
        assert_raise Claudex.Tool.SchemaError,
                     ~r/ASCII letters, digits, _ and -, up to 128/,
                     fn ->
                       Code.compile_string("""
                       defmodule BadName#{System.unique_integer([:positive])} do
                         use Claudex.Tool

                         @doc "Checks."
                         @tool true
                         @spec #{unquote(name)}() :: boolean()
                         def #{unquote(name)}, do: true
                       end
                       """)
                     end
      end
    end

    test "a name ending in a newline can't be a tool" do
      assert_raise Claudex.Tool.SchemaError, ~r/ASCII letters, digits, _ and -, up to 128/, fn ->
        Code.compile_string("""
        defmodule NewlineName#{System.unique_integer([:positive])} do
          use Claudex.Tool

          @doc "Checks."
          @tool true
          def unquote(:"ping\\n")(), do: true
        end
        """)
      end
    end

    test "a 128-character name is a tool" do
      name = String.duplicate("a", 128)

      [{module, _bytecode}] =
        Code.compile_string("""
        defmodule LongName#{System.unique_integer([:positive])} do
          use Claudex.Tool

          @doc "Checks."
          @tool true
          @spec #{name}() :: boolean()
          def #{name}, do: true
        end
        """)

      assert [%{name: ^name}] = Claudex.Tool.list(module)
    end

    test "a pattern bound to a variable is named for the variable, on either side of =" do
      [{module, _bytecode}] =
        Code.compile_string("""
        defmodule BoundPatterns#{System.unique_integer([:positive])} do
          use Claudex.Tool

          @doc "Merges two maps."
          @tool true
          @spec merge(map(), map()) :: map()
          def merge(%{} = left, right = %{}), do: Map.merge(left, right)
        end
        """)

      assert [%{input_schema: %{properties: properties, required: ["left", "right"]}}] =
               Claudex.Tool.list(module)

      assert Map.keys(properties) == ["left", "right"]

      assert Claudex.Tool.call(module, "merge", %{"left" => %{"a" => 1}, "right" => %{"b" => 2}}) ==
               {:ok, %{"a" => 1, "b" => 2}}
    end

    test "an ignored variable bound to a pattern yields the other side's name" do
      [{module, _bytecode}] =
        Code.compile_string("""
        defmodule IgnoredSide#{System.unique_integer([:positive])} do
          use Claudex.Tool

          @doc "Echoes."
          @tool true
          @spec echo(map()) :: map()
          def echo(_ = %{} = value), do: value
        end
        """)

      assert [%{input_schema: %{required: ["value"]}}] = Claudex.Tool.list(module)
    end

    for param <- [~S("Tokyo"), ":low", "_", "nil", "false", "<<_x::binary>>", "[_h | _t]"] do
      test "a lone parameter written as #{param} is published as arg, with a warning" do
        warning =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            [{module, _bytecode}] =
              Code.compile_string("""
              defmodule Unnamed#{System.unique_integer([:positive])} do
                use Claudex.Tool

                @doc "Gets it."
                @tool true
                def get(#{unquote(param)}), do: :ok
              end
              """)

            send(self(), {:module, module})
          end)

        assert_received {:module, module}
        assert [%{input_schema: %{required: ["arg"]}}] = Claudex.Tool.list(module)

        assert warning =~
                 "with no name to publish, so Claude sees it as \"arg\". " <>
                   "Name it, as in `#{unquote(param)} = _name`"
      end
    end

    test "a bound pattern with a default is named for its variable and optional" do
      [{module, _bytecode}] =
        Code.compile_string("""
        defmodule DefaultedPattern#{System.unique_integer([:positive])} do
          use Claudex.Tool

          @doc "Echoes the options."
          @tool true
          def echo(%{} = opts \\\\ %{"k" => 1}), do: opts
        end
        """)

      assert [%{input_schema: %{properties: properties, required: []}}] =
               Claudex.Tool.list(module)

      assert Map.keys(properties) == ["opts"]
      assert Claudex.Tool.call(module, "echo", %{}) == {:ok, %{"k" => 1}}
    end

    test "the unnamed-parameter warning points at the tool's definition" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string(
            """
            defmodule Located#{System.unique_integer([:positive])} do
              use Claudex.Tool

              @doc "Gets it."
              @tool true
              def get("Tokyo"), do: :ok
            end
            """,
            "located.ex"
          )
        end)

      assert warning =~ "located.ex:6"
    end

    test "two parameters that share a name raise before any unnamed warning" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Claudex.Tool.SchemaError, fn ->
            Code.compile_string("""
            defmodule RaisesFirst#{System.unique_integer([:positive])} do
              use Claudex.Tool

              @doc "Merges."
              @tool true
              def merge(%{}, %{}), do: :ok
            end
            """)
          end
        end)

      refute warning =~ "no name to publish"
    end

    test "two unnamed parameters can't be a tool, since both would be arg" do
      assert_raise Claudex.Tool.SchemaError,
                   ~r/merge\/2 in TwoUnnamed\d+, but `%\{\}` and `%\{\}` would both be the property "arg"/,
                   fn ->
                     Code.compile_string("""
                     defmodule TwoUnnamed#{System.unique_integer([:positive])} do
                       use Claudex.Tool

                       @doc "Merges."
                       @tool true
                       def merge(%{}, %{}), do: :ok
                     end
                     """)
                   end
    end

    test "two parameters that publish the same name can't be a tool" do
      assert_raise Claudex.Tool.SchemaError,
                   ~r/pick\/2 in SharedParam\d+, but `x` and `_x` would both be the property "x"/,
                   fn ->
                     Code.compile_string("""
                     defmodule SharedParam#{System.unique_integer([:positive])} do
                       use Claudex.Tool

                       @doc "Picks."
                       @tool true
                       def pick(x, _x), do: x
                     end
                     """)
                   end
    end

    test "an unnamed parameter under args_schema is not warned about" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule OwnSchema#{System.unique_integer([:positive])} do
            use Claudex.Tool

            @doc "Gets it."
            @tool %{args_schema: %{"arg" => %{type: "string"}}}
            def get("Tokyo"), do: :ok
          end
          """)
        end)

      refute warning =~ "no name to publish"
    end

    test "a tool with no @doc warns and falls back to a placeholder" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule NoDocTool#{System.unique_integer([:positive])} do
            use Claudex.Tool
            @tool true
            @spec a() :: :ok
            def a, do: :ok
          end
          """)
        end)

      assert warning =~ "is tagged `@tool` but has no `@doc`"
    end

    test ":args merges descriptions into the inferred schema" do
      [{module, _bin}] =
        define(~s(%{args: [a: "the first number", b: "the second number"]}), """
        @spec add(integer(), integer()) :: integer()
        def add(a, b), do: a + b
        """)

      [tool] = module.__tools__()

      assert %{
               "a" => %{type: "integer", description: "the first number"},
               "b" => %{type: "integer", description: "the second number"}
             } = tool.input_schema.properties

      assert tool.input_schema.required == ["a", "b"]
    end

    test ":args describes an underscored parameter by its published name" do
      [{module, _bin}] =
        define(~s(%{args: [a: "still described"]}), """
        @spec ignore(integer()) :: :ok
        def ignore(_a), do: :ok
        """)

      [tool] = module.__tools__()

      assert %{"a" => %{description: "still described"}} = tool.input_schema.properties
    end

    test ":args naming no argument raises rather than dropping the description" do
      assert_raise Claudex.Tool.SchemaError,
                   ~r/describes "typo", but .* has no such argument/,
                   fn ->
                     define(~s(%{args: [typo: "nothing is called this"]}))
                   end
    end

    test ":args must be a keyword list of descriptions" do
      assert_raise Claudex.Tool.SchemaError, ~r/:args must be a keyword list/, fn ->
        define(~s(%{args: %{a: "a map, not a keyword list"}}))
      end

      assert_raise Claudex.Tool.SchemaError, ~r/:args must be a keyword list/, fn ->
        define(~s(%{args: [a: :not_a_string]}))
      end
    end

    test "a strict tool moves what strict mode rejects into the argument's description" do
      [{module, _bin}] =
        define(
          "%{strict: true}",
          "@spec a(non_neg_integer(), map()) :: :ok\ndef a(_count, _opts), do: :ok"
        )

      [tool] = module.__tools__()

      assert tool.input_schema.properties["count"] == %{
               type: "integer",
               description: "{minimum: 0}"
             }

      assert tool.input_schema.properties["opts"].additionalProperties == false
    end

    test "a strict tool with an argument of no concrete type names it at compile time" do
      assert_raise Claudex.Tool.SchemaError,
                   ~r/`value` has no type the API can be told about/,
                   fn ->
                     define("%{strict: true}", "@spec a(any()) :: :ok\ndef a(_value), do: :ok")
                   end
    end

    test "a tool that isn't strict keeps the bounds its @spec implies" do
      [{module, _bin}] =
        define("true", "@spec a(non_neg_integer()) :: :ok\ndef a(_count), do: :ok")

      [tool] = module.__tools__()

      assert tool.input_schema.properties["count"] == %{type: "integer", minimum: 0}
    end

    test "an args_schema with no property for a required parameter can't be a tool" do
      assert_raise Claudex.Tool.SchemaError,
                   ~r/get\/1 in ToolOpts\d+, but its :args_schema has no property "opts"/,
                   fn ->
                     define(
                       ~s(%{args_schema: %{"arg" => %{type: "object"}}}),
                       "def get(%{} = opts), do: opts"
                     )
                   end
    end

    test "an args_schema keyed by atoms covers the parameters it names" do
      assert [{_module, _bin}] =
               define(~s(%{args_schema: %{opts: %{type: "object"}}}), "def get(opts), do: opts")
    end

    test "a strict tool's args_schema is sent as written" do
      [{module, _bin}] =
        define(~s(%{strict: true, args_schema: %{"n" => %{type: "integer", minimum: 0}}}))

      [tool] = module.__tools__()

      assert tool.input_schema.properties["n"] == %{type: "integer", minimum: 0}
    end

    test "valid options still compile" do
      assert [{_module, _bin}] = define("%{strict: true}")
      assert [{_module, _bin}] = define(~s(%{args_schema: %{"a" => %{type: "string"}}}))
    end
  end

  test "list/1 raises for a module that doesn't use Claudex.Tool" do
    assert_raise ArgumentError, ~r/doesn't `use Claudex.Tool`/, fn ->
      Claudex.Tool.list(String)
    end
  end

  test "result/3 builds a tool_result content block" do
    assert Claudex.Tool.result("toolu_1", "42") == %{
             type: "tool_result",
             tool_use_id: "toolu_1",
             content: "42",
             is_error: false
           }

    assert Claudex.Tool.result("toolu_1", "boom", is_error: true) == %{
             type: "tool_result",
             tool_use_id: "toolu_1",
             content: "boom",
             is_error: true
           }
  end

  defmodule GuardedTools do
    use Claudex.Tool

    @doc "Refuses on purpose."
    @tool true
    @spec refuse() :: String.t()
    def refuse, do: raise(Claudex.Tool.Error, "not today")

    @doc "Has a bug in it."
    @tool true
    @spec break() :: String.t()
    def break, do: raise("kaboom")
  end

  test "call/3 runs a tool by the name Claude used, matching args by name" do
    assert Claudex.Tool.call(AgentTools, "add", %{"b" => 2, "a" => 1}) == {:ok, 3}
  end

  test "call/3 tells a deliberate refusal apart from a bug" do
    assert {:error, %CallError{type: :tool_refused, message: "not today"}} =
             Claudex.Tool.call(GuardedTools, "refuse", %{})

    assert {:error, %CallError{type: :tool_raised, message: message}} =
             Claudex.Tool.call(GuardedTools, "break", %{})

    assert message =~ "kaboom"
  end
end

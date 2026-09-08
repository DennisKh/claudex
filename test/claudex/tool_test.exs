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
    defp define(opts) do
      Code.compile_string("""
      defmodule BadOpts#{System.unique_integer([:positive])} do
        use Claudex.Tool
        @doc "X."
        @tool #{opts}
        @spec a() :: :ok
        def a, do: :ok
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

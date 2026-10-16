defmodule Claudex.Live.ToolsTest do
  @moduledoc """
  End-to-end coverage of tool use: schema derivation, the API's tool call, and
  the follow-up carrying results back.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Message, Messages, Tool}
  alias Claudex.Stream.Accumulator
  alias Claudex.Stream.Event.ContentBlockDelta

  defmodule WeatherTool do
    @moduledoc false
    use Tool

    @doc "Returns the current temperature, in Celsius, for a city."
    @tool true
    @spec get_temperature(String.t()) :: String.t()
    def get_temperature("Tokyo"), do: "24"
    def get_temperature(_city), do: "18"

    @doc "Returns the average of the temperatures given, in Celsius."
    @tool true
    @spec average([String.t(), ...]) :: String.t()
    def average(temperatures) do
      temperatures
      |> Enum.map(&String.to_integer/1)
      |> then(&"#{div(Enum.sum(&1), length(&1))}")
    end

    @doc "Converts a temperature from Celsius to Fahrenheit."
    @tool %{args: [degrees: "The temperature in Celsius.", precision: "Decimal places."]}
    @spec convert(degrees :: number(), non_neg_integer()) :: String.t()
    def convert(degrees, precision) do
      Float.round(degrees * 9 / 5 + 32, precision) |> to_string()
    end
  end

  defmodule StrictTool do
    @moduledoc false
    use Tool

    @doc "Repeats a word a number of times."
    @tool %{strict: true}
    @spec repeat(String.t(), non_neg_integer()) :: String.t()
    def repeat(word, times), do: String.duplicate(word, times)
  end

  defmodule Arithmetic do
    @moduledoc false
    use Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b), do: a + b
  end

  defmodule Strings do
    @moduledoc false
    use Tool

    @doc "Joins two strings."
    @tool true
    @spec add(String.t(), String.t()) :: String.t()
    def add(a, b), do: a <> b
  end

  test "two modules with a tool of the same name are refused", %{client: client} do
    assert {:error, %Claudex.Error{status: 400, message: message}} =
             Messages.count_tokens(client, %{
               model: @model,
               tools: [Arithmetic, Strings],
               messages: [Message.user("Add 2 and 3.")]
             })

    assert message =~ "unique"
  end

  test "a strict tool with a bounded integer is accepted and called", %{client: client} do
    assert {:ok, message} =
             Messages.create(client, %{
               model: @model,
               max_tokens: 256,
               tools: StrictTool,
               tool_choice: %{type: "tool", name: "repeat"},
               messages: [Message.user("Repeat the word echo three times.")]
             })

    assert [%{name: "repeat", input: %{"word" => _word, "times" => times}}] =
             Message.tool_uses(message)

    assert is_integer(times) and times >= 0
  end

  test "round-trips a tool call: request, dispatch, and follow-up", %{client: client} do
    tools = Tool.list(WeatherTool)
    messages = [Message.user("What is the temperature in Paris?")]

    {:ok, first} =
      client
      |> Recorder.record_json("tool_use")
      |> Messages.create(%{
        model: @model,
        max_tokens: 256,
        tools: tools,
        tool_choice: %{type: "tool", name: "get_temperature"},
        messages: messages
      })

    assert first.stop_reason == "tool_use"

    [tool_use] = Message.tool_uses(first)
    assert tool_use.name == "get_temperature"
    assert is_map(tool_use.input)

    {:ok, temperature} = Tool.call(WeatherTool, tool_use.name, tool_use.input)

    follow_up =
      Message.append(messages, [
        first,
        Message.tool_results([Tool.result(tool_use.id, temperature)])
      ])

    {:ok, second} =
      Messages.create(client, %{model: @model, max_tokens: 128, tools: tools, messages: follow_up})

    assert second.role == "assistant"
    assert Message.text(second) =~ "18"
  end

  test "handles every tool call in one assistant turn", %{client: client} do
    tools = Tool.list(WeatherTool)

    messages = [
      Message.user(
        "What is the temperature in Paris and in Tokyo? " <>
          "Call get_temperature separately for each city."
      )
    ]

    {:ok, first} =
      Messages.create(client, %{model: @model, max_tokens: 512, tools: tools, messages: messages})

    tool_uses = Message.tool_uses(first)
    assert tool_uses != []

    results =
      Enum.map(tool_uses, fn tool_use ->
        {:ok, temperature} = Tool.call(WeatherTool, tool_use.name, tool_use.input)
        Tool.result(tool_use.id, temperature)
      end)

    follow_up = Message.append(messages, [first, Message.tool_results(results)])

    {:ok, second} =
      Messages.create(client, %{model: @model, max_tokens: 256, tools: tools, messages: follow_up})

    assert Message.text(second) != ""
  end

  test "arguments named in the @spec reach the API as a schema", %{client: client} do
    [_temperature, _average, convert] = Tool.list(WeatherTool)

    # One argument named in the spec, one bare: both are read the same, and
    # each property keeps the name the function gave it.
    assert convert.input_schema.properties == %{
             "degrees" => %{type: "number", description: "The temperature in Celsius."},
             "precision" => %{
               type: "integer",
               description: "Decimal places.",
               minimum: 0
             }
           }

    assert {:ok, tokens} =
             Messages.count_tokens(client, %{
               model: @model,
               tools: WeatherTool,
               messages: [Message.user("hi")]
             })

    assert tokens > 0
  end

  test "a non-empty list argument is a schema the API accepts", %{client: client} do
    [_temperature, average, _convert] = Tool.list(WeatherTool)

    assert average.input_schema.properties["temperatures"] == %{
             type: "array",
             items: %{type: "string"},
             minItems: 1
           }

    # Free: count_tokens validates a tool's schema the way create/2 would.
    assert {:ok, tokens} =
             Messages.count_tokens(client, %{
               model: @model,
               tools: WeatherTool,
               messages: [Message.user("hi")]
             })

    assert tokens > 0
  end

  test "a toolset call goes back with its toolset_name and is answered", %{client: client} do
    params = %{
      model: "claude-haiku-5-5",
      max_tokens: 256,
      tools: [%{type: "computer_toolset_20260801"}],
      messages: [Message.user("Take a screenshot of the screen, nothing else.")]
    }

    {:ok, first} = client |> Recorder.record_json("toolset_tool_use") |> Messages.create(params)

    [call] = Message.tool_uses(first)
    assert call.toolset_name == "computer"

    history =
      Message.append(params.messages, [
        first,
        Message.tool_results([Tool.result(call, "The screen is blank.")])
      ])

    assert {:ok, _second} = Messages.create(client, %{params | messages: history})
  end

  test "a reply cut off inside a tool call goes back without the call and is accepted",
       %{client: client} do
    messages = [Message.user("What is the temperature in Paris?")]

    params = %{
      model: @model,
      max_tokens: 256,
      tools: Tool.list(WeatherTool),
      tool_choice: %{type: "tool", name: "get_temperature"},
      messages: messages
    }

    events =
      client
      |> Recorder.record_stream("tool_use_stream")
      |> Messages.stream!(params)
      |> Enum.to_list()

    cut_off = cut_at_first_argument(events)

    assert [%Claudex.ContentBlock.ToolUse{}] = Message.tool_uses(cut_off)

    history = Message.append(messages, [cut_off, Message.user("Go on.")])

    params = params |> Map.delete(:tool_choice) |> Map.put(:messages, history)

    assert {:ok, _reply} = Messages.create(client, params)
  end

  # The state a cancel leaves when it lands on the call's first argument fragment.
  defp cut_at_first_argument(events) do
    {before, [fragment | _rest]} =
      Enum.split_while(events, &(not match?(%ContentBlockDelta{delta: {:input_json, _}}, &1)))

    Enum.reduce(before ++ [fragment], Accumulator.new(), &Accumulator.add(&2, &1))
    |> Accumulator.message()
  end
end

defmodule Claudex.Live.ToolsTest do
  @moduledoc """
  End-to-end coverage of tool use: schema derivation, the API's tool call, and
  the follow-up carrying results back.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Message, Messages, Tool}

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
end

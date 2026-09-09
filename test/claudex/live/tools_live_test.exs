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
end

defmodule Arithmetix do
  @moduledoc """
  Asks Claude to evaluate an arithmetic expression using one tool per
  operation, and prints the whole conversation afterwards.
  """

  alias Arithmetix.Tools
  alias Claudex.ToolRunner.Turn

  @doc "Runs the conversation and prints a trace of it."
  @spec run() :: :ok
  def run do
    Claudex.Telemetry.attach_default_logger()

    tast = "Compute (5+3)*2 - 6/0"

    Claudex.new()
    |> Claudex.ToolRunner.stream(%{
      model: "claude-haiku-4-5",
      max_tokens: 612,
      tools: Tools,
      # Dev tip:
      # tool_choice 'any' forces Claude to run at least one tool. This means no 'end_turn' will ever occur on its own.
      # You need to handle this yourself: provide an 'exit' tool as shown in this example, and catch it to stop execution.
      # Yes, you can skip tool_choice 'any', but the model will not run all your tools, even if the system prompt says so,
      # especially weaker models.
      # Also, sometimes a model can perform an operation without calling your tool, even if it's valid to do so. So if it's
      # required that a tool must be used, because, let's say, you log it or important checks must happen for every
      # action, tool_choice 'any' is your only option.
      tool_choice: %{type: "any"},
      system: system(),
      messages: [Claudex.Message.user(task)]
    })
    |> Enum.reduce_while(nil, fn turn, _last ->
      if finished?(turn), do: {:halt, turn}, else: {:cont, turn}
    end)
    |> summary()
  end

  defp finished?(%Turn{tool_uses: [%{name: "finish"} | _], tool_results: [_result | _]}), do: true
  defp finished?(%Turn{}), do: false

  defp system do
    """
    Break down each arithmetic operation to find a dedicated tool and USE IT - This is a strict requirement!
    Follow the rule of arithmetic operation order: BODMAS (Brackets, Orders, Division, Multiplication, Addition, Subtraction). Always work from left to right for multiplication/division and addition/subtraction.
    Call exactly one tool per turn. Do not call 'finish' until you have seen the tool result of the last arithmetic operation. In case of arithmetic operation failure - return an error with the arguments that failed.
    When all arithmetic operations are done - call 'finish' tool. If an error occurred during an arithmetic operation - call 'finish' with 'final_result': 'error'
    """
  end

  defp summary(%Turn{messages: messages}) do
    IO.puts("─── Full trace ───")

    Enum.each(messages, &classify/1)

    IO.puts("─── Final answer ───")

    messages
    |> List.last()
    |> Map.get(:content, [])
    |> List.first(%{})
    |> Map.get(:content, "")
    |> IO.puts()
  end

  defp classify(%{role: role, content: content}) when is_binary(content) do
    IO.puts("#{label(role)} #{content}")
  end

  defp classify(%{content: content}) when is_list(content) do
    Enum.each(content, &classify_content/1)
  end

  defp label("user"), do: "[User]"
  defp label("assistant"), do: "[AI Message]"

  defp classify_content(%{type: "text", text: text}) do
    IO.puts("[AI Message] #{text}")
  end

  defp classify_content(%{type: "tool_use", name: name, input: input}) do
    IO.puts("[Tool Call] name: #{name}, input: #{inspect(input)}")
  end

  defp classify_content(%{type: "tool_result", content: content}) do
    IO.puts("[Tool Result] #{content}")
  end
end

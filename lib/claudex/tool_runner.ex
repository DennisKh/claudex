defmodule Claudex.ToolRunner do
  @default_max_turns 10

  @moduledoc """
  Runs a tool conversation: send, run whatever Claude asks for, send the
  results back, repeat until it stops asking.

      {:ok, turn} =
        Claudex.ToolRunner.run(client, %{
          model: "claude-opus-5",
          max_tokens: 1024,
          tools: MyApp.Tools,
          messages: [Claudex.Message.user("What is 12 plus 30?")]
        })

      Claudex.Message.text(turn.message)  # the final reply
      turn.messages                       # the whole conversation
      turn.stop                           # :completed | :refusal | :max_turns

  `stream/3` hands you one turn at a time instead, so you can watch the
  conversation, log it, or stop it:

      client
      |> Claudex.ToolRunner.stream(params)
      |> Enum.reduce_while(nil, fn turn, _last ->
        if interesting?(turn), do: {:cont, turn}, else: {:halt, turn}
      end)

  ## Tools decide what they will and won't do

  There's no approval callback here, because the tool is the right place for
  that. A tool that refuses raises `Claudex.Tool.Error`, and Claude sees the
  reason as an error result and adapts — it's an ordinary `@tool` function that
  happens to guard itself:

      @doc "Reads a file from the workspace."
      @tool true
      @spec read_file(String.t()) :: String.t()
      def read_file(path) do
        unless allowed?(path), do: raise Claudex.Tool.Error, "path is outside the workspace"

        File.read!(path)
      end

  Any other exception becomes an error result too, with the exception type in
  the content and a warning in your logs — a bug in a tool shouldn't read to
  Claude like a policy decision, and shouldn't end the conversation either.

  Whatever a tool returns is the result: a binary is sent as-is, anything else
  is JSON-encoded. Returning is success; raising is failure. A tool's return
  value is your own data, so it can't double as an error channel.

  `:tools` takes several modules as a list. Keep tool names unique across
  them — Claude is told about both, but only the one from the last module
  listed can be called.

  ## Options

    * `:max_turns` - how many times to go around before giving up, defaulting
      to #{@default_max_turns}. The last turn then carries `stop: :max_turns`.
  """

  require Logger

  alias Claudex.{Client, Error, Message, Messages, Tool}
  alias Claudex.ContentBlock.ToolUse
  alias Claudex.Tool.CallError
  alias Claudex.ToolRunner.Turn

  @doc """
  Runs the conversation until Claude stops asking for tools, returning the last
  turn.

      {:ok, %Turn{message: message, messages: history, stop: :completed}} =
        Claudex.ToolRunner.run(client, params)

  It returns a `Claudex.ToolRunner.Turn`, the same thing `stream/3` yields.
  `message` is the final reply, `messages` the whole conversation,
  and `stop` says why it ended: `:completed`, `:refusal`, or `:max_turns`.
  Match on `stop` rather than assuming Claude finished; hitting the turn limit
  is not an error, and looks identical without it.

  Returns `{:error, %Claudex.Error{}}` if a request fails.
  """
  @spec run(Client.t(), map() | keyword()) :: {:ok, Turn.t()} | {:error, Error.t()}
  @spec run(Client.t(), map() | keyword(), keyword()) :: {:ok, Turn.t()} | {:error, Error.t()}
  def run(%Client{} = client, params, opts \\ []) do
    client
    |> stream(params, opts)
    |> Enum.reduce(nil, fn turn, _last -> turn end)
    |> case do
      %Turn{} = turn -> {:ok, turn}
      nil -> {:error, %Error{type: :bad_request, message: "no turns ran"}}
    end
  rescue
    error in Error -> {:error, error}
  end

  @doc """
  Returns a lazy stream of `Claudex.ToolRunner.Turn` structs, one per reply.

  Nothing happens until you enumerate it. Tools for a turn have already run by
  the time you see that turn, so halting stops the conversation rather than
  cancelling work — a tool that shouldn't run guards itself instead.

  Enumerating raises `Claudex.Error` if a request fails.
  """
  @spec stream(Client.t(), map() | keyword()) :: Enumerable.t()
  @spec stream(Client.t(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, params, opts \\ []) do
    params = Map.new(params)
    registry = Tool.registry(params[:tools])
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

    Stream.unfold({Message.append([], params[:messages] || []), 1}, fn
      :done -> nil
      {messages, index} -> next_turn(client, params, registry, messages, index, max_turns)
    end)
    |> Stream.map(&emit_turn/1)
  end

  defp emit_turn(%Turn{} = turn) do
    :telemetry.execute(
      [:claudex, :tool_runner, :turn],
      %{tool_calls: length(turn.tool_uses)},
      %{index: turn.index}
    )

    if turn.stop do
      :telemetry.execute([:claudex, :tool_runner, :stop], %{turns: turn.index}, %{stop: turn.stop})
    end

    turn
  end

  defp next_turn(client, params, registry, messages, index, max_turns) do
    message = request!(client, params, messages)
    messages = Message.append(messages, message)
    tool_uses = tool_uses(message)

    turn = %Turn{message: message, index: index, tool_uses: tool_uses, messages: messages}

    cond do
      # A refusal ends the conversation. Running its tool calls would fire side
      # effects Claude never confirmed, and the results couldn't be replayed.
      message.stop_reason == "refusal" -> {%{turn | stop: :refusal}, :done}
      tool_uses == [] -> {%{turn | stop: :completed}, :done}
      true -> continue(turn, registry, messages, index, max_turns)
    end
  end

  defp continue(turn, registry, messages, index, max_turns) do
    results = Enum.map(turn.tool_uses, &run_tool(&1, registry))

    messages = Message.append(messages, Message.tool_results(results))
    turn = %{turn | tool_results: results, messages: messages}

    # The limit is checked here rather than before the next request so the last
    # turn carries the reason. The tool results are already in the history, so
    # the conversation can be resumed by passing it back.
    if index >= max_turns do
      {%{turn | stop: :max_turns}, :done}
    else
      {turn, {messages, index + 1}}
    end
  end

  defp request!(client, params, messages) do
    case Messages.create(client, Map.put(params, :messages, messages)) do
      {:ok, message} -> message
      {:error, error} -> raise error
    end
  end

  defp tool_uses(%Message{content: content}) do
    Enum.filter(content, &match?(%ToolUse{}, &1))
  end

  defp run_tool(%ToolUse{} = tool_use, registry) do
    :telemetry.span([:claudex, :tool], %{tool: tool_use.name}, fn ->
      case Map.fetch(registry, tool_use.name) do
        {:ok, module} ->
          call(module, tool_use)

        :error ->
          {Tool.result(tool_use.id, "no tool named #{tool_use.name}", is_error: true),
           %{tool: tool_use.name, outcome: :unknown_tool}}
      end
    end)
  end

  defp call(module, tool_use) do
    case Tool.call(module, tool_use.name, tool_use.input) do
      {:ok, value} ->
        {Tool.result(tool_use.id, encode(value)), %{tool: tool_use.name, outcome: :ok}}

      {:error, reason} ->
        {Tool.result(tool_use.id, describe(tool_use, reason), is_error: true),
         %{tool: tool_use.name, outcome: outcome(reason)}}
    end
  end

  defp outcome(%CallError{type: :tool_refused}), do: :refused
  defp outcome(%CallError{}), do: :failed

  defp encode(value) when is_binary(value), do: value

  # A tool returns whatever it returns — a tuple, a PID, a struct with no
  # encoder. None of that is JSON, and none of it should take the loop down,
  # so an unencodable result is described rather than encoded.
  defp encode(value) do
    JSON.encode!(value)
  rescue
    Protocol.UndefinedError -> inspect(value)
  end

  # A bug is worth seeing in the logs, and worth labelling so Claude doesn't
  # read it as a considered decision. Everything else — a refusal above all —
  # goes back as the error wrote it.
  defp describe(tool_use, %CallError{type: :tool_raised, message: message}) do
    Logger.warning("Claudex tool #{tool_use.name} failed: #{message}")

    "the tool failed: #{message}"
  end

  defp describe(_tool_use, %CallError{message: message}), do: message
end

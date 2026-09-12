defmodule Claudex.ToolRunner do
  @default_max_turns 20

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
      turn.stop                           # :completed | :truncated | :refusal | :max_turns

  A turn the API pauses part-way through a server-side tool loop
  (`stop_reason: "pause_turn"`) resumes on its own. The history goes back
  unchanged and the conversation carries on, so a pause costs a turn but does
  not end anything.

  `stream/3` hands you one turn at a time instead, so you can watch the
  conversation, log it, or stop it:

      client
      |> Claudex.ToolRunner.stream(params)
      |> Enum.reduce_while(nil, fn turn, _last ->
        if interesting?(turn), do: {:cont, turn}, else: {:halt, turn}
      end)

  ## Tools decide what they will and won't do

  A tool is the first place to decide that, ahead of any `:before_call` gate.
  A tool that refuses raises `Claudex.Tool.Error`, and Claude sees the
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

    * `:max_turns` - how many requests the conversation may make before giving
      up, defaulting to #{@default_max_turns}. Tool rounds and resumed pauses
      both count. The last turn then carries `stop: :max_turns`.
    * `:before_call` - a function run on each `Claudex.ContentBlock.ToolUse`
      before the tool does, returning `:ok` or `{:deny, reason}`
    * `:on_event` - a function run on each `Claudex.Stream.Event` as it
      arrives, for showing a reply while it is still being written

  ## Approving a tool call

  `:before_call` is where a call gets gated — a confirmation prompt, an
  allowlist, a human clicking approve. It runs per call, before dispatch:

      Claudex.ToolRunner.run(client, params,
        before_call: fn %Claudex.ContentBlock.ToolUse{name: name, input: input} ->
          if MyApp.Approvals.granted?(name, input) do
            :ok
          else
            {:deny, "The user declined this tool call."}
          end
        end
      )

  A denial sends `reason` back as a `tool_result` with `is_error: true` and the
  conversation carries on, so Claude can explain itself or try another way. The
  tool is never called, so nothing it would have done happens.

  The function is called in the process enumerating the stream, so it can block
  — waiting on a `GenServer.call` for a decision from a UI, say.

  ## Watching a reply arrive

  Every request the loop makes is a streaming one, so `:on_event` sees each
  `Claudex.Stream.Event` as it lands, on every turn:

      Claudex.ToolRunner.run(client, params,
        on_event: fn
          %Claudex.Stream.Event.ContentBlockDelta{delta: {:text, chunk}} ->
            IO.write(chunk)

          _event ->
            :ok
        end
      )

  It runs in the process driving the loop, one event at a time, and the next
  event is only read once it returns. A callback that forwards deltas to a web
  page streams tokens there, but the turn still ends if the process driving the
  loop stops.

  ## Running the loop somewhere else

  The loop blocks the process it runs in, so a LiveView or a GenServer runs it
  in a task and lets `:on_event` send the deltas back:

      ref = make_ref()
      parent = self()

      Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
        Claudex.ToolRunner.run(client, params, on_event: &send(parent, {:reply, ref, &1}))
      end)

  Matching that `ref` where the messages arrive keeps a reply from a
  conversation the user has left out of the one on screen:

      def handle_info({:reply, ref, event}, %{assigns: %{ref: ref}} = socket)
      def handle_info({:reply, _stale, _event}, socket), do: {:noreply, socket}

  The conversation ends with the task, so `:before_call` fits a decision the
  user makes now. One that arrives in a later request needs storing, and the
  loop re-entered from there.
  """

  require Logger

  alias Claudex.{Client, Error, Message, Messages, Tool}
  alias Claudex.ContentBlock.ToolUse
  alias Claudex.Stream.Accumulator
  alias Claudex.Tool.CallError
  alias Claudex.ToolRunner.Turn

  @doc """
  Runs the conversation until Claude stops asking for tools, returning the last
  turn.

      {:ok, %Turn{message: message, messages: history, stop: :completed}} =
        Claudex.ToolRunner.run(client, params)

  It returns a `Claudex.ToolRunner.Turn`, the same thing `stream/3` yields.
  `message` is the last reply, `messages` the whole conversation, and `stop`
  says why it ended: `:completed`, `:truncated`, `:refusal`, or `:max_turns`.
  A conversation
  that ran out of turns is `{:ok, turn}` like any other, and reads as a
  finished one everywhere except `stop`.

  A conversation that ran tools or paused says part of what it has to say
  before each of those, so `message` carries the last stretch of the reply
  rather than all of it. `messages` holds the rest.

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

    config = %{
      client: client,
      params: params,
      registry: Tool.registry(params[:tools]),
      max_turns: Keyword.get(opts, :max_turns, @default_max_turns),
      before_call: Keyword.get(opts, :before_call),
      on_event: Keyword.get(opts, :on_event, &ignore/1)
    }

    Stream.unfold({Message.append([], params[:messages] || []), 1}, fn
      :done -> nil
      {messages, index} -> next_turn(config, messages, index)
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

  defp next_turn(config, messages, index) do
    message = request!(config, messages)
    messages = Message.append(messages, message)
    tool_uses = Message.tool_uses(message)

    turn = %Turn{message: message, index: index, tool_uses: tool_uses, messages: messages}

    case Message.stop(message) do
      stop when stop in [:refusal, :truncated] ->
        {%{turn | stop: stop}, :done}

      :paused when tool_uses == [] ->
        resume(config, turn, messages, index)

      _other when tool_uses != [] ->
        continue(config, turn, messages, index)

      _other ->
        {%{turn | stop: :completed}, :done}
    end
  end

  defp continue(config, turn, messages, index) do
    results = Enum.map(turn.tool_uses, &run_tool(&1, config))

    messages = Message.append(messages, Message.tool_results(results))

    advance(config, %{turn | tool_results: results, messages: messages}, messages, index)
  end

  # The API picks a paused turn up from the trailing server tool block, so it
  # resumes on the history as it stands.
  defp resume(config, turn, messages, index), do: advance(config, turn, messages, index)

  defp advance(config, turn, messages, index) do
    if index >= config.max_turns do
      {%{turn | stop: :max_turns}, :done}
    else
      {turn, {messages, index + 1}}
    end
  end

  defp request!(config, messages) do
    config.client
    |> Messages.stream!(Map.put(config.params, :messages, messages))
    |> Enum.reduce(Accumulator.new(), fn event, accumulator ->
      config.on_event.(event)
      Accumulator.add(accumulator, event)
    end)
    |> Accumulator.message()
    |> case do
      nil -> raise Error.stream_error("the stream ended without starting a message")
      message -> message
    end
  end

  defp ignore(_event), do: :ok

  defp run_tool(%ToolUse{} = tool_use, config) do
    case decide(config.before_call, tool_use) do
      :ok -> dispatch(tool_use, config.registry)
      {:deny, reason} -> denied(tool_use, reason)
    end
  end

  defp decide(nil, _tool_use), do: :ok

  defp decide(before_call, tool_use) when is_function(before_call, 1) do
    case before_call.(tool_use) do
      :ok ->
        :ok

      {:deny, reason} when is_binary(reason) ->
        {:deny, reason}

      other ->
        raise ArgumentError,
              ":before_call must return :ok or {:deny, reason}, got: #{inspect(other)}"
    end
  end

  defp denied(tool_use, reason) do
    report(tool_use, :denied, fn -> Tool.result(tool_use.id, reason, is_error: true) end)
  end

  defp dispatch(tool_use, registry) do
    case Map.fetch(registry, tool_use.name) do
      {:ok, module} ->
        call(module, tool_use)

      :error ->
        report(tool_use, :unknown_tool, fn ->
          Tool.result(tool_use.id, "no tool named #{tool_use.name}", is_error: true)
        end)
    end
  end

  defp call(module, tool_use) do
    case Tool.call(module, tool_use.name, tool_use.input) do
      {:ok, value} -> Tool.result(tool_use.id, encode(value))
      {:error, reason} -> Tool.result(tool_use.id, describe(tool_use, reason), is_error: true)
    end
  end

  defp report(tool_use, outcome, build_result) do
    :telemetry.span([:claudex, :tool], %{tool: tool_use.name}, fn ->
      {build_result.(), %{tool: tool_use.name, outcome: outcome}}
    end)
  end

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

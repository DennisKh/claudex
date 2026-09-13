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

  `params` takes exactly what `Claudex.Messages.create/2` takes, so `:system`,
  `:thinking`, `:tool_choice` and the rest go in the same map. The options
  below are Claudex's own and go in the keyword list after it.

  > #### Tip {: .tip}
  >
  > `tool_choice: %{type: "any"}` forces Claude to run at least one tool. This means no `end_turn` will ever occur on its own.
  > You need to handle this yourself: provide an `exit` tool and catch it to stop execution, the way the
  > [arithmetix example](https://github.com/DennisKh/claudex/tree/main/examples/arithmetix) does with its `finish` tool.
  > Yes, you can skip `tool_choice: %{type: "any"}`, but the model will not run all your tools, even if the system prompt says so,
  > especially weaker models.
  >
  > Also, sometimes a model can perform an operation without calling your tool, even if it's valid to do so. So if it's
  > required that a tool must be used, because, let's say, you log it or important checks must happen for every
  > action, `tool_choice: %{type: "any"}` is your only option.

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
        unless allowed?(path), do: raise(Claudex.Tool.Error, "path is outside the workspace")

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
    * `:cancel_ref` - tags every request the loop makes, so a
      `Claudex.Stream.Handle` carrying the same reference stops the one in
      flight. `stream_to/3` sets it itself.

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

  The loop blocks the process it runs in, so a LiveView or a GenServer hands it
  to `stream_to/3`, which runs it in a linked process and sends back each event
  as it arrives and each turn as it completes:

      {:ok, handle} =
        Claudex.ToolRunner.stream_to(client, %{
          model: "claude-opus-5",
          max_tokens: 1024,
          tools: MyApp.Tools,
          messages: [Claudex.Message.user("What is 12 plus 30?")]
        })

      def handle_info({:claudex, ref, {:event, event}}, %{assigns: %{ref: ref}} = socket)
      def handle_info({:claudex, ref, {:turn, turn}}, %{assigns: %{ref: ref}} = socket)
      def handle_info({:claudex, _stale, _message}, socket), do: {:noreply, socket}

  Matching the handle's `ref` keeps a reply from a conversation the user has
  left out of the one on screen, and `Claudex.Stream.cancel/1` on that handle
  stops the request in flight.

  The conversation ends with that process, so `:before_call` fits a decision
  the user makes now. One that arrives in a later request needs storing, and
  the loop re-entered from there.
  """

  require Logger

  alias Claudex.{Client, Error, Message, Messages, Tool}
  alias Claudex.ContentBlock.ToolUse
  alias Claudex.Stream.{Accumulator, Event, Forwarder, Handle}
  alias Claudex.Tool.CallError
  alias Claudex.ToolRunner.Turn

  @typedoc """
  An option for `run/3`, `stream/3` and `stream_to/3`, each described under
  "Options" in `Claudex.ToolRunner`.
  """
  @type option ::
          {:max_turns, pos_integer()}
          | {:before_call, (ToolUse.t() -> :ok | {:deny, String.t()})}
          | {:on_event, (Event.t() -> any())}

  @typedoc """
  An option for `run/3` and `stream/3`: any `t:option/0`, plus the reference
  that cancels the request in flight.
  """
  @type loop_option :: option() | {:cancel_ref, reference()}

  @typedoc """
  An option for `stream_to/3`: any `t:option/0`, plus the ones that say where
  its messages go, which are `Claudex.Messages.stream_to/3`'s. It sets its own
  `:cancel_ref` from the handle it returns.
  """
  @type stream_to_option :: option() | Messages.stream_to_option()

  @doc """
  Runs the conversation until Claude stops asking for tools, returning the last
  turn.

      {:ok, %Turn{message: message, messages: history, stop: :completed}} =
        Claudex.ToolRunner.run(client, params)

  `params` takes exactly what `Claudex.Messages.create/2` takes; `opts` are
  the runner's own, listed in `Claudex.ToolRunner`.

  It returns a `Claudex.ToolRunner.Turn`, the same thing `stream/3` yields.
  `message` is the last reply, `messages` the whole conversation, and `stop`
  says why it ended: `:completed`, `:truncated`, `:refusal`, or `:max_turns`.
  A conversation that ran out of turns is `{:ok, turn}` like any other, and
  reads as a finished one everywhere except `stop`.

  A conversation that ran tools or paused says part of what it has to say
  before each of those, so `message` carries the last stretch of the reply
  rather than all of it. `messages` holds the rest.

  Returns `{:error, %Claudex.Error{}}` if a request fails.
  """
  @spec run(Client.t(), map() | keyword()) :: {:ok, Turn.t()} | {:error, Error.t()}
  @spec run(Client.t(), map() | keyword(), [loop_option()]) ::
          {:ok, Turn.t()} | {:error, Error.t()}
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

  `params` takes exactly what `Claudex.Messages.create/2` takes; `opts` are the
  runner's own, listed in `Claudex.ToolRunner`.

  Nothing happens until you enumerate it. Tools for a turn have already run by
  the time you see that turn, so halting stops the conversation rather than
  cancelling work — a tool that shouldn't run guards itself instead.

  Each turn carries the usage of its own request, so a run's cost is the sum
  over the stream:

      client
      |> Claudex.ToolRunner.stream(params)
      |> Enum.reduce(%{input: 0, output: 0}, fn turn, total ->
        %{
          input: total.input + turn.message.usage.input_tokens,
          output: total.output + turn.message.usage.output_tokens
        }
      end)

  `Claudex.Usage.merge/2` is not that sum. It folds the two halves of one
  streamed reply and replaces field by field, so reducing turns with it reports
  the last request's counts as if they were the total.

  `Enum.reduce_while/3` drives a state machine, and stopping the reduce stops
  the conversation:

      client
      |> Claudex.ToolRunner.stream(params, before_call: &MyApp.Session.approve/1)
      |> Enum.reduce_while(MyApp.Session.new(), fn turn, session ->
        case MyApp.Session.apply_turn(session, turn) do
          {:continue, session} -> {:cont, session}
          {:finished, session} -> {:halt, session}
        end
      end)

  `run/3` is this reduce keeping only the last turn, so anything a run has to
  add up belongs here instead.

  A cancel sent with `:cancel_ref` stops the request in flight. The turn it
  interrupts arrives with `stop: :truncated` and its tool calls unrun, and the
  stream ends there.

  Enumerating raises `Claudex.Error` if a request fails.
  """
  @spec stream(Client.t(), map() | keyword()) :: Enumerable.t()
  @spec stream(Client.t(), map() | keyword(), [loop_option()]) :: Enumerable.t()
  def stream(%Client{} = client, params, opts \\ []) do
    params = Map.new(params)

    config = %{
      client: client,
      params: params,
      registry: Tool.registry(params[:tools]),
      max_turns: Keyword.get(opts, :max_turns, @default_max_turns),
      before_call: Keyword.get(opts, :before_call),
      on_event: Keyword.get(opts, :on_event, &ignore/1),
      cancel_ref: Keyword.get_lazy(opts, :cancel_ref, &make_ref/0)
    }

    Stream.unfold({Message.append([], params[:messages] || []), 1}, fn
      :done -> nil
      {messages, index} -> next_turn(config, messages, index)
    end)
    |> Stream.map(&emit_turn/1)
  end

  @doc """
  Runs the conversation in its own process and returns straight away,
  delivering each turn to a mailbox.

      {:ok, handle} =
        Claudex.ToolRunner.stream_to(client, %{
          model: "claude-opus-5",
          max_tokens: 1024,
          tools: MyApp.Tools,
          messages: [Claudex.Message.user("What is 12 plus 30?")]
        })

      def handle_info({:claudex, ref, {:event, event}}, %{assigns: %{ref: ref}} = socket)
      def handle_info({:claudex, ref, {:turn, turn}}, %{assigns: %{ref: ref}} = socket)

  `:monitor` says whether the conversation belongs to the reader or to you:

      # independent of whoever is reading: a reader that restarts picks it up
      {:ok, handle} = Claudex.ToolRunner.stream_to(client, params, to: reader)

      # run on the reader's behalf: no reader - nothing to finish
      {:ok, handle} = Claudex.ToolRunner.stream_to(client, params, to: reader, monitor: true)

  `params` takes exactly what `Claudex.Messages.create/2` takes, so `:system`,
  `:thinking` and the rest go in that same map; `opts` are the runner's own,
  listed in `Claudex.ToolRunner`.

  Returns `{:ok, handle}`, a `Claudex.Stream.Handle` carrying the `ref` every
  message is tagged with, and then sends:

    * `{:claudex, ref, {:event, event}}` for each `Claudex.Stream.Event`, on
      every turn
    * `{:claudex, ref, {:turn, turn}}` as each `Claudex.ToolRunner.Turn`
      completes, tools already run
    * `{:claudex, ref, :done}` when the conversation ends
    * `{:claudex, ref, {:error, %Claudex.Error{}}}` if a request fails
    * `{:claudex, ref, :cancelled}` after `Claudex.Stream.cancel/1`

  Every failure arrives as an `{:error, error}` message, a missing `:model` or
  `:max_tokens` included, so there is nothing to match on the return.

  `:to`, `:ref` and `:monitor` work as they do on `Claudex.Messages.stream_to/3`:
  where the messages go, what tags them, and whether the conversation ends with
  them. Every other option is the runner's own, listed in `Claudex.ToolRunner`,
  and an `:on_event` of your own still runs with the event forwarded either way.

  The forwarding process is linked to the caller, so it dies with it, and it
  is also where `:before_call` runs. A gate that asks another process for a
  decision blocks the forwarder rather than the caller, which is the point;
  send that process a message and wait for its answer rather than calling into
  one that is waiting on you.

  The process being delivered to is not linked, so the conversation carries on
  when it goes away, and you decide what that means: keep the handle and call
  `Claudex.Stream.cancel/1` when the run is no longer wanted. That suits a
  reader whose disappearance says nothing about the work, a view that
  reconnects or a consumer its supervisor restarts.

  `monitor: true` stops the conversation as soon as that process goes away, so
  a run nobody is left to read stops costing tokens. It stops at the next turn
  boundary, since the turn already in flight has been paid for, and it stops
  silently: the process the messages were for is the one that has gone. A
  caller that needs to know monitors the handle's `pid`.

  `Claudex.Stream.cancel/1` stops the request in flight, so a reply being
  written stops part-way and the tool calls it had got as far as asking for
  are not run. A tool already running is not interrupted, and the turn it
  belongs to is never sent.
  """
  @spec stream_to(Client.t(), map() | keyword()) :: {:ok, Handle.t()}
  @spec stream_to(Client.t(), map() | keyword(), [stream_to_option()]) :: {:ok, Handle.t()}
  def stream_to(%Client{} = client, params, opts \\ []) do
    {forwarder_opts, runner_opts} = Keyword.split(opts, [:to, :ref, :monitor])

    Forwarder.start(forwarder_opts, fn sink ->
      client
      |> stream(params, forwarding(runner_opts, sink))
      |> Forwarder.forward_each(sink, :turn)
    end)
  end

  defp forwarding(opts, sink) do
    on_event = Keyword.get(opts, :on_event, &ignore/1)

    opts
    |> Keyword.put(:cancel_ref, sink.ref)
    |> Keyword.put(:on_event, fn event ->
      on_event.(event)
      Forwarder.deliver(sink, {:event, event})
    end)
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

    resolve_turn(config, %Turn{
      message: message,
      index: index,
      tool_uses: Message.tool_uses(message),
      messages: messages
    })
  end

  # canceled stream may carry stop_reason `nil`
  defp resolve_turn(_config, %Turn{message: %Message{stop_reason: nil}} = turn) do
    {%{turn | stop: :truncated}, :done}
  end

  defp resolve_turn(config, %Turn{messages: messages, index: index} = turn) do
    case Message.stop(turn.message) do
      stop when stop in [:refusal, :truncated] ->
        {%{turn | stop: stop}, :done}

      :paused when turn.tool_uses == [] ->
        resume(config, turn, messages, index)

      _other when turn.tool_uses != [] ->
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
    |> Messages.stream!(Map.put(config.params, :messages, messages),
      cancel_ref: config.cancel_ref
    )
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

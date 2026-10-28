defmodule Claudex.Stream.Forwarder do
  @moduledoc """
  The process behind `Claudex.Messages.stream_to/3` and
  `Claudex.ToolRunner.stream_to/3`: it consumes a stream and forwards each
  item to another process as a message.

  It stops when whoever started it exits, for any reason. There's no
  `child_spec/1`, so it can't go in a supervision tree.

  The process being delivered to is not linked, so a stream carries on when
  that one goes away. Starting it with `monitor: true` watches it instead, and
  the stream stops when it does.

  Starting it with `every:` puts a batcher between the two, which holds events
  for a window and sends them as one `{:events, [event]}` message. Anything
  else it is handed goes out after the batch before it.
  """

  require Logger

  alias Claudex.{ChunkStream, Client, Error, Tracing}
  alias Claudex.Stream.{Connection, Handle}

  @typedoc """
  Where a forwarded stream delivers: the process, the reference tagging every
  message, and the monitor watching that process, which is nil unless the
  stream was started with `monitor: true`.
  """
  @type sink :: %{to: pid(), ref: reference(), monitor: reference() | nil}

  @typedoc """
  Consumes a stream, delivering each item to `sink`, and says how it ended.
  """
  @type consume :: (sink() -> :running | :cancelled | :unreachable)

  @doc false
  @spec start(keyword(), consume()) :: {:ok, Handle.t()}
  def start(opts, consume) when is_function(consume, 1) do
    to = Keyword.get(opts, :to, self())
    ref = Keyword.get(opts, :ref, make_ref())
    monitor? = Keyword.get(opts, :monitor, false)
    every = opts |> Keyword.get(:every) |> validate_every()
    caller = self()
    callers = [caller | Process.get(:"$callers", [])]
    context = Tracing.context()

    pid =
      spawn_link(fn ->
        watch(caller, to, ref, monitor?)
        Process.put(:"$callers", callers)
        Tracing.attach(context)
        monitor = if monitor?, do: Process.monitor(to)

        sink = %{to: through(to, ref, every), ref: ref, monitor: monitor}

        forward(consume, sink)
        await_batcher(sink, every)
      end)

    {:ok, %Handle{ref: ref, pid: pid}}
  end

  @doc false
  @spec events(Client.t(), map(), keyword()) :: {:ok, Handle.t()}
  def events(%Client{} = client, body, opts) do
    session = Keyword.get(opts, :session)

    start(opts, fn sink ->
      client
      |> Connection.stream(body, cancel_ref: sink.ref, session: session)
      |> forward_each(sink, :event)
    end)
  end

  @doc false
  @spec forward_each(Enumerable.t(), sink(), atom()) :: :running | :cancelled | :unreachable
  def forward_each(enumerable, sink, tag) do
    Enum.reduce_while(enumerable, :running, fn item, :running ->
      case halt_reason(sink) do
        nil ->
          deliver(sink, {tag, item})
          {:cont, :running}

        reason ->
          {:halt, reason}
      end
    end)
  end

  @doc false
  @spec deliver(sink(), term()) :: :ok
  def deliver(%{to: to, ref: ref}, payload) do
    send(to, {:claudex, ref, payload})

    :ok
  rescue
    ArgumentError -> warn_unreachable(to)
  end

  defp watch(caller, to, ref, monitor?) do
    forwarder = self()
    ChunkStream.watch(caller, fn -> Process.exit(forwarder, :shutdown) end)

    # The forwarder is linked to the caller, so a reader that goes away cancels it
    if monitor?, do: ChunkStream.watch(to, fn -> send(forwarder, {:claudex_cancel, ref}) end)
  end

  defp validate_every(nil), do: nil
  defp validate_every(every) when is_integer(every) and every > 0, do: every

  defp validate_every(every) do
    raise ArgumentError,
          ":every must be a positive integer of milliseconds, got: #{inspect(every)}"
  end

  defp through(to, _ref, nil), do: to

  defp through(to, ref, every) do
    sink = %{to: to, ref: ref, monitor: nil}

    spawn_link(fn -> collect(%{sink: sink, every: every, buffered: [], window: nil}) end)
  end

  defp await_batcher(_sink, nil), do: :ok

  defp await_batcher(%{to: batcher, ref: ref}, _every) do
    stopped = Process.monitor(batcher)
    send(batcher, {:claudex_stop, ref})

    receive do
      {:DOWN, ^stopped, :process, ^batcher, _reason} -> :ok
    end
  end

  defp collect(%{sink: %{ref: ref}, window: window} = batch) do
    receive do
      {:claudex, ^ref, {:event, event}} ->
        batch |> add(event) |> collect()

      {:timeout, ^window, {:claudex_window, ^ref}} ->
        batch |> deliver_batch() |> collect()

      {:timeout, _closed, {:claudex_window, ^ref}} ->
        collect(batch)

      {:claudex, ^ref, payload} ->
        batch = deliver_batch(batch)
        deliver(batch.sink, payload)
        collect(batch)

      {:claudex_stop, ^ref} ->
        :ok
    end
  end

  defp add(%{buffered: []} = batch, event) do
    window = :erlang.start_timer(batch.every, self(), {:claudex_window, batch.sink.ref})

    %{batch | buffered: [event], window: window}
  end

  defp add(batch, event), do: %{batch | buffered: [event | batch.buffered]}

  defp deliver_batch(%{buffered: []} = batch), do: batch

  defp deliver_batch(batch) do
    deliver(batch.sink, {:events, Enum.reverse(batch.buffered)})

    %{batch | buffered: [], window: nil}
  end

  defp warn_unreachable(to) do
    if !Process.get(:claudex_unreachable_logged) do
      # once per stream
      Process.put(:claudex_unreachable_logged, true)

      Logger.warning(
        "Claudex has no process registered as #{inspect(to)}, so the stream's " <>
          "messages are being dropped. It keeps running; cancel it if nothing wants it."
      )
    end

    :ok
  end

  defp forward(consume, sink) do
    consume.(sink) |> outcome(sink) |> finish(sink)
  rescue
    error in Claudex.Error -> fail(error, sink)
    error -> fail(wrap(error), sink)
  catch
    kind, reason -> fail(Error.stream_error("the stream #{kind}: #{inspect(reason)}"), sink)
  end

  defp wrap(error) do
    Error.stream_error("#{inspect(error.__struct__)}: #{Exception.message(error)}")
  end

  # A cancel lands mid-request, so the stream it interrupts can end by raising
  # rather than by running out. That is the cancel arriving, not a failure.
  defp fail(error, sink) do
    case halt_reason(sink) do
      :cancelled -> deliver(sink, :cancelled)
      :unreachable -> :ok
      nil -> deliver(sink, {:error, error})
    end
  end

  defp finish(:running, sink), do: deliver(sink, :done)
  defp finish(:cancelled, sink), do: deliver(sink, :cancelled)
  defp finish(:unreachable, _sink), do: :ok

  # The transport halts on the cancel message and puts it back, so a stream
  # that was cancelled while the model was thinking still reports as cancelled
  defp outcome(:running, sink), do: halt_reason(sink) || :running
  defp outcome(state, _sink), do: state

  defp halt_reason(%{ref: ref, monitor: nil}) do
    receive do
      {:claudex_cancel, ^ref} -> :cancelled
    after
      0 -> nil
    end
  end

  defp halt_reason(%{ref: ref, monitor: monitor}) do
    receive do
      {:claudex_cancel, ^ref} -> :cancelled
      {:DOWN, ^monitor, :process, _to, _reason} -> :unreachable
    after
      0 -> nil
    end
  end
end

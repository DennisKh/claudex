defmodule Claudex.Stream.Forwarder do
  @moduledoc """
  The process behind `Claudex.Messages.stream_to/3` and
  `Claudex.ToolRunner.stream_to/3`: it consumes a stream and forwards each
  item to another process as a message.

  It's linked to whoever started it, so it goes away with them. There's no
  `child_spec/1`, so it can't go in a supervision tree.
  """

  alias Claudex.{Client, Error}
  alias Claudex.Stream.{Connection, Handle}

  @typedoc """
  Consumes a stream, sending each item to `to` tagged with `ref`, and says
  whether it ran out or was cancelled.
  """
  @type consume :: (pid(), reference() -> :running | :cancelled)

  @doc false
  @spec start(keyword(), consume()) :: {:ok, Handle.t()}
  def start(opts, consume) when is_function(consume, 2) do
    to = Keyword.get(opts, :to, self())
    ref = Keyword.get(opts, :ref, make_ref())
    callers = [self() | Process.get(:"$callers", [])]

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", callers)
        forward(consume, to, ref)
      end)

    {:ok, %Handle{ref: ref, pid: pid}}
  end

  @doc false
  @spec events(Client.t(), map(), keyword()) :: {:ok, Handle.t()}
  def events(%Client{} = client, body, opts) do
    start(opts, fn to, ref ->
      client |> Connection.stream(body, ref) |> forward_each(to, ref, :event)
    end)
  end

  @doc false
  @spec forward_each(Enumerable.t(), pid(), reference(), atom()) :: :running | :cancelled
  def forward_each(enumerable, to, ref, tag) do
    Enum.reduce_while(enumerable, :running, fn item, :running ->
      if cancelled?(ref) do
        {:halt, :cancelled}
      else
        send(to, {:claudex, ref, {tag, item}})
        {:cont, :running}
      end
    end)
  end

  defp forward(consume, to, ref) do
    consume.(to, ref) |> outcome(ref) |> finish(to, ref)
  rescue
    error in Claudex.Error -> fail(error, to, ref)
    error -> fail(wrap(error), to, ref)
  catch
    kind, reason -> fail(Error.stream_error("the stream #{kind}: #{inspect(reason)}"), to, ref)
  end

  # This process is linked to whoever started it, so anything that escapes here
  # takes their LiveView or GenServer down — the opposite of what stream_to/3
  # promises.
  defp wrap(error) do
    Error.stream_error("#{inspect(error.__struct__)}: #{Exception.message(error)}")
  end

  # A cancel lands mid-request, so the stream it interrupts can end by raising
  # rather than by running out. That is the cancel arriving, not a failure.
  defp fail(error, to, ref) do
    if cancelled?(ref) do
      send(to, {:claudex, ref, :cancelled})
    else
      send(to, {:claudex, ref, {:error, error}})
    end
  end

  defp finish(:running, to, ref), do: send(to, {:claudex, ref, :done})
  defp finish(:cancelled, to, ref), do: send(to, {:claudex, ref, :cancelled})

  # The transport halts on the cancel message and puts it back, so a stream
  # that was cancelled while the model was thinking still reports as cancelled
  defp outcome(:running, ref), do: if(cancelled?(ref), do: :cancelled, else: :running)
  defp outcome(state, _ref), do: state

  defp cancelled?(ref) do
    receive do
      {:claudex_cancel, ^ref} -> true
    after
      0 -> false
    end
  end
end

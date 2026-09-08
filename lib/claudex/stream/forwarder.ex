defmodule Claudex.Stream.Forwarder do
  @moduledoc """
  The process behind `Claudex.Messages.stream_to/3`: it consumes a stream and
  forwards each event to another process as a message.

  It's linked to whoever started it, so it goes away with them. There's no
  `child_spec/1`, so it can't go in a supervision tree.
  """

  alias Claudex.{Client, Error}
  alias Claudex.Stream.{Connection, Handle}

  @doc false
  @spec start(Client.t(), map(), keyword()) :: {:ok, Handle.t()}
  def start(%Client{} = client, params, opts) do
    to = Keyword.get(opts, :to, self())
    ref = Keyword.get(opts, :ref, make_ref())
    callers = [self() | Process.get(:"$callers", [])]

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", callers)
        forward(client, params, to, ref)
      end)

    {:ok, %Handle{ref: ref, pid: pid}}
  end

  defp forward(client, params, to, ref) do
    client
    |> Connection.stream(params, ref)
    |> Enum.reduce_while(:running, fn event, :running -> forward_event(event, to, ref) end)
    |> outcome(ref)
    |> finish(to, ref)
  rescue
    error in Claudex.Error -> send(to, {:claudex, ref, {:error, error}})
    error -> send(to, {:claudex, ref, {:error, wrap(error)}})
  catch
    kind, reason ->
      send(
        to,
        {:claudex, ref, {:error, Error.stream_error("the stream #{kind}: #{inspect(reason)}")}}
      )
  end

  # This process is linked to whoever started it, so anything that escapes here
  # takes their LiveView or GenServer down — the opposite of what stream_to/3
  # promises.
  defp wrap(error) do
    Error.stream_error("#{inspect(error.__struct__)}: #{Exception.message(error)}")
  end

  defp forward_event(event, to, ref) do
    if cancelled?(ref) do
      {:halt, :cancelled}
    else
      send(to, {:claudex, ref, {:event, event}})
      {:cont, :running}
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

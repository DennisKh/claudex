defmodule Claudex.Stream.Forwarder do
  @moduledoc """
  The process behind `Claudex.Messages.stream_to/3`: it consumes a stream and
  forwards each event to another process as a message.

  It's linked to whoever started it, so it goes away with them. There's no
  `child_spec/1`: a stream can't be restarted — you can't resume a half-read
  reply, and re-running the request bills it again — so a supervisor has
  nothing useful to do with one beyond what the link already provides.
  """

  alias Claudex.{Client, Error, Messages}
  alias Claudex.Stream.Handle

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
    |> Messages.stream!(params)
    |> Enum.reduce_while(:running, fn event, :running -> forward_event(event, to, ref) end)
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

  # Cancellation is checked between events rather than by killing this
  # process, so the stream's own cleanup runs and the connection is closed
  # properly.
  defp cancelled?(ref) do
    receive do
      {:claudex_cancel, ^ref} -> true
    after
      0 -> false
    end
  end
end

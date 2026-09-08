defmodule Claudex.Stream do
  @moduledoc """
  Helpers for a stream of events from `Claudex.Messages.stream!/2` or
  `Claudex.Messages.stream_to/3`.

  Use `final_message/1` or `text/1` when you want the finished reply and the
  events were only a means to get there:

      client
      |> Claudex.Messages.stream!(params)
      |> Claudex.Stream.text()

  For the event-by-event view, enumerate the stream yourself and match on the
  structs in `Claudex.Stream.Event`.
  """

  alias Claudex.{Error, Message}
  alias Claudex.Stream.{Accumulator, Handle}

  @doc """
  Consumes a stream and returns the message it describes.

  Returns `{:error, %Claudex.Error{}}` if the request fails, if the API sends
  an error part-way through, or if the stream ends without ever starting a
  message.
  """
  @spec final_message(Enumerable.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  def final_message(events) do
    events
    |> Enum.reduce(Accumulator.new(), &Accumulator.add(&2, &1))
    |> Accumulator.message()
    |> case do
      nil -> {:error, Error.stream_error("the stream ended without starting a message")}
      message -> {:ok, message}
    end
  rescue
    error in Error -> {:error, error}
  end

  @doc "Consumes a stream and returns just the reply text."
  @spec text(Enumerable.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def text(events) do
    with {:ok, message} <- final_message(events), do: {:ok, Message.text(message)}
  end

  @doc """
  Stops a stream started with `Claudex.Messages.stream_to/3`.

  The request is closed straight away, without waiting for the next event, and
  `{:claudex, ref, :cancelled}` follows.
  """
  @spec cancel(Handle.t()) :: :ok
  def cancel(%Handle{ref: ref, pid: pid}) do
    send(pid, {:claudex_cancel, ref})
    :ok
  end
end

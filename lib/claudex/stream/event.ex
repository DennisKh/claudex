defmodule Claudex.Stream.Event do
  @moduledoc """
  The events the Messages API sends while it streams a reply, in the order they
  arrive:

    * `Claudex.Stream.Event.MessageStart`: the message shell, once
    * `Claudex.Stream.Event.ContentBlockStart`: a block begins, one group per
      block
    * `Claudex.Stream.Event.ContentBlockDelta`: its text, thinking, or tool
      input, repeatedly
    * `Claudex.Stream.Event.ContentBlockStop`: that block is complete
    * `Claudex.Stream.Event.MessageDelta`: the stop reason and the final usage
    * `Claudex.Stream.Event.MessageStop`: the end
    * `Claudex.Stream.Event.Unknown`: an event type this version doesn't model

  Match on the struct to handle the one you care about:

      %Event.ContentBlockDelta{delta: {:text, chunk}} -> IO.write(chunk)

  Keep-alive `ping` events never reach you, and an `error` event the API sends
  mid-stream comes back as a `Claudex.Error`, ending the reply there.
  """

  alias Claudex.Error
  alias Claudex.Stream.SSE

  alias Claudex.Stream.Event.{
    ContentBlockDelta,
    ContentBlockStart,
    ContentBlockStop,
    MessageDelta,
    MessageStart,
    MessageStop,
    Unknown
  }

  @type t ::
          MessageStart.t()
          | ContentBlockStart.t()
          | ContentBlockDelta.t()
          | ContentBlockStop.t()
          | MessageDelta.t()
          | MessageStop.t()
          | Unknown.t()

  # Data that isn't a JSON object is an error, the same as an `error` event.
  @doc false
  @spec from_sse(SSE.Event.t()) :: {:ok, t()} | :ignore | {:error, Error.t()}
  def from_sse(%SSE.Event{name: "ping"}), do: :ignore

  def from_sse(%SSE.Event{name: "error", data: data}) do
    case Jason.decode(data) do
      {:ok, body} when is_map(body) ->
        {:error, Error.from_stream_event(body)}

      _not_an_object ->
        {:error, Error.stream_error("the API sent an error event Claudex couldn't read", data)}
    end
  end

  def from_sse(%SSE.Event{data: data}) do
    case Jason.decode(data) do
      {:ok, json} when is_map(json) ->
        {:ok, decode(json)}

      _not_an_object ->
        {:error,
         Error.stream_error("a stream event carried something other than a JSON object", data)}
    end
  end

  @doc """
  Builds the event struct for one decoded event payload.

  Falls back to `Claudex.Stream.Event.Unknown` for a type not modeled yet.
  """
  @spec decode(map()) :: t()
  def decode(%{"type" => "message_start"} = json), do: MessageStart.decode(json)
  def decode(%{"type" => "content_block_start"} = json), do: ContentBlockStart.decode(json)
  def decode(%{"type" => "content_block_delta"} = json), do: ContentBlockDelta.decode(json)
  def decode(%{"type" => "content_block_stop"} = json), do: ContentBlockStop.decode(json)
  def decode(%{"type" => "message_delta"} = json), do: MessageDelta.decode(json)
  def decode(%{"type" => "message_stop"} = json), do: MessageStop.decode(json)
  def decode(json), do: Unknown.decode(json)
end

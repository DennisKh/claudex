defmodule Claudex.Stream.SSE do
  @moduledoc """
  Decodes a Server-Sent Events byte stream into `Claudex.Stream.SSE.Event`
  structs. `Claudex.Stream.Event` is what those become once the data is
  decoded as one of Claude's events.

  Incremental and network-free: feed it whatever bytes arrived, get back the
  events those bytes completed plus a decoder holding the leftover tail.

      {events, decoder} = SSE.decode(SSE.new(), chunk)

  Nothing is emitted until an event's terminating blank line arrives, so a
  chunk that splits an event mid-JSON yields nothing until the rest lands.
  Call `flush/1` when the connection closes to drain a final event that came
  without its terminator.
  """

  alias Claudex.Stream.SSE.Event

  @event_terminators ["\n\n", "\r\n\r\n", "\r\r"]
  @line_terminators ["\r\n", "\r", "\n"]

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @doc "Builds a decoder with an empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds `chunk` to the decoder, returning the events it completed and a
  decoder carrying whatever is still incomplete.

  Blocks holding only comments or unrecognised fields produce no event, so
  the returned list can be empty for a chunk that did contain data.
  """
  @spec decode(t(), binary()) :: {[Event.t()], t()}
  def decode(%__MODULE__{buffer: buffer}, chunk) do
    {blocks, rest} = split_blocks(buffer <> chunk, [])
    events = blocks |> Enum.map(&parse_block/1) |> Enum.reject(&is_nil/1)

    {events, %__MODULE__{buffer: rest}}
  end

  @doc """
  Drains the buffer, returning any event held in it and an empty decoder.

  A well-behaved server terminates every event with a blank line, so this is
  usually empty. It exists so an unterminated final event isn't silently
  dropped when the connection closes.
  """
  @spec flush(t()) :: {[Event.t()], t()}
  def flush(%__MODULE__{buffer: buffer}) do
    case parse_block(buffer) do
      nil -> {[], new()}
      event -> {[event], new()}
    end
  end

  defp split_blocks(data, blocks) do
    case :binary.match(data, @event_terminators) do
      :nomatch ->
        {Enum.reverse(blocks), data}

      {block_size, terminator_size} ->
        <<block::binary-size(block_size), _terminator::binary-size(terminator_size),
          rest::binary>> = data

        split_blocks(rest, [block | blocks])
    end
  end

  defp parse_block(block) do
    block
    |> String.split(@line_terminators)
    |> Enum.reduce(%{name: nil, data: [], id: nil, retry: nil}, &parse_line/2)
    |> to_event()
  end

  defp parse_line(":" <> _comment, fields), do: fields

  defp parse_line(line, fields) do
    case String.split(line, ":", parts: 2) do
      [field, value] -> put_field(fields, field, strip_leading_space(value))
      [field] -> put_field(fields, field, "")
    end
  end

  defp put_field(fields, "event", value), do: %{fields | name: value}

  defp put_field(fields, "data", value), do: %{fields | data: [value | fields.data]}

  # The SSE spec says an id containing a NUL byte must be ignored outright.
  defp put_field(fields, "id", value) do
    if String.contains?(value, <<0>>), do: fields, else: %{fields | id: value}
  end

  defp put_field(fields, "retry", value) do
    case Integer.parse(value) do
      {retry, ""} when retry >= 0 -> %{fields | retry: retry}
      _not_an_integer -> fields
    end
  end

  defp put_field(fields, _ignored_field, _value), do: fields

  defp strip_leading_space(" " <> value), do: value
  defp strip_leading_space(value), do: value

  # A block carrying only `id:` or `retry:` has no payload to decode, and the
  # typed layer would reject its empty data as malformed. Drop it here.
  defp to_event(%{name: nil, data: []}), do: nil

  defp to_event(fields) do
    %Event{
      name: fields.name,
      data: fields.data |> Enum.reverse() |> Enum.join("\n"),
      id: fields.id,
      retry: fields.retry
    }
  end
end

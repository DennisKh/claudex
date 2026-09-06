defmodule Claudex.Stream.Accumulator do
  @moduledoc """
  Folds stream events back into the `Claudex.Message` they describe — the
  same struct `Claudex.Messages.create/2` would have returned.

      events
      |> Enum.reduce(Accumulator.new(), &Accumulator.add(&2, &1))
      |> Accumulator.message()

  `message/1` works at any point, so you can take a snapshot mid-stream. One
  thing to know: a tool call's `input` is only filled in once its
  `content_block_stop` arrives, because the API sends the arguments as JSON
  fragments that are only parseable together.
  """

  alias Claudex.ContentBlock.{Text, Thinking, ToolUse}
  alias Claudex.{Message, Usage}

  alias Claudex.Stream.Event.{
    ContentBlockDelta,
    ContentBlockStart,
    ContentBlockStop,
    MessageDelta,
    MessageStart
  }

  defstruct message: nil, blocks: %{}, tool_input: %{}

  @type t :: %__MODULE__{
          message: Message.t() | nil,
          blocks: %{non_neg_integer() => Claudex.ContentBlock.t()},
          tool_input: %{non_neg_integer() => String.t()}
        }

  @doc "Builds an empty accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Folds one event in.

  Events that arrive before `message_start`, or that refer to a block index
  that never started, are ignored — a stream that never starts a message is
  reported by `Claudex.Stream.final_message/1` instead.
  """
  @spec add(t(), Claudex.Stream.Event.t()) :: t()
  def add(%__MODULE__{} = accumulator, %MessageStart{message: message}) do
    %{accumulator | message: message, blocks: %{}, tool_input: %{}}
  end

  def add(%__MODULE__{message: nil} = accumulator, _event), do: accumulator

  def add(%__MODULE__{} = accumulator, %ContentBlockStart{index: index, content_block: block}) do
    %{accumulator | blocks: Map.put(accumulator.blocks, index, block)}
  end

  def add(%__MODULE__{} = accumulator, %ContentBlockDelta{index: index, delta: delta}) do
    apply_delta(accumulator, index, delta)
  end

  def add(%__MODULE__{} = accumulator, %ContentBlockStop{index: index}) do
    case Map.pop(accumulator.tool_input, index) do
      {nil, _tool_input} ->
        accumulator

      {json, tool_input} ->
        %{
          accumulator
          | tool_input: tool_input,
            blocks: put_tool_input(accumulator.blocks, index, json)
        }
    end
  end

  def add(%__MODULE__{} = accumulator, %MessageDelta{} = event) do
    message = %{
      accumulator.message
      | stop_reason: event.stop_reason,
        stop_sequence: event.stop_sequence,
        stop_details: event.stop_details || accumulator.message.stop_details,
        container: event.container || accumulator.message.container,
        usage: merge_usage(accumulator.message.usage, event.usage)
    }

    %{accumulator | message: message}
  end

  def add(%__MODULE__{} = accumulator, _event), do: accumulator

  @doc """
  Returns the message built so far, or `nil` if the stream hasn't started
  one yet.
  """
  @spec message(t()) :: Message.t() | nil
  def message(%__MODULE__{message: nil}), do: nil

  def message(%__MODULE__{message: message, blocks: blocks}) do
    content =
      blocks
      |> Enum.sort_by(fn {index, _block} -> index end)
      |> Enum.map(fn {_index, block} -> block end)

    %{message | content: content}
  end

  defp apply_delta(accumulator, index, {:input_json, chunk}) do
    %{accumulator | tool_input: Map.update(accumulator.tool_input, index, chunk, &(&1 <> chunk))}
  end

  defp apply_delta(accumulator, index, {:text, chunk}) do
    update_block(accumulator, index, fn
      %Text{} = block -> %{block | text: (block.text || "") <> chunk}
      block -> block
    end)
  end

  defp apply_delta(accumulator, index, {:thinking, chunk}) do
    update_block(accumulator, index, fn
      %Thinking{} = block -> %{block | thinking: (block.thinking || "") <> chunk}
      block -> block
    end)
  end

  defp apply_delta(accumulator, index, {:signature, signature}) do
    update_block(accumulator, index, fn
      %Thinking{} = block -> %{block | signature: signature}
      block -> block
    end)
  end

  defp apply_delta(accumulator, index, {:citation, citation}) do
    update_block(accumulator, index, fn
      %Text{} = block -> %{block | citations: block.citations ++ [citation]}
      block -> block
    end)
  end

  defp apply_delta(accumulator, _index, {:unknown, _delta}), do: accumulator

  defp update_block(accumulator, index, fun) do
    case Map.fetch(accumulator.blocks, index) do
      {:ok, block} -> %{accumulator | blocks: Map.put(accumulator.blocks, index, fun.(block))}
      :error -> accumulator
    end
  end

  defp put_tool_input(blocks, index, json) do
    with {:ok, %ToolUse{} = block} <- Map.fetch(blocks, index),
         {:ok, input} when is_map(input) <- JSON.decode(json) do
      Map.put(blocks, index, %{block | input: input})
    else
      _incomplete_or_not_a_tool_call -> blocks
    end
  end

  defp merge_usage(usage, nil), do: usage

  defp merge_usage(usage, %Usage{} = delta) do
    delta
    |> Map.from_struct()
    |> Enum.reduce(usage, fn
      {_field, nil}, usage -> usage
      {field, value}, usage -> Map.put(usage, field, value)
    end)
  end
end

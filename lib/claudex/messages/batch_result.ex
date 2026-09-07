defmodule Claudex.Messages.BatchResult do
  @moduledoc """
  One request's outcome in a batch: the `custom_id` it was submitted with
  and the `result` it ended in.

  Match on `result` to handle each outcome:

      case result do
        %BatchResult{custom_id: id, result: {:ok, message}} -> store(id, message)
        %BatchResult{result: {:error, error}} -> log(error)
        %BatchResult{result: :canceled} -> :ok
        %BatchResult{result: :expired} -> requeue(result.custom_id)
      end

  Expired requests aren't billed — those are ones the batch's 24 hours ran
  out on before they reached the model.
  """

  alias Claudex.{Error, Message}

  defstruct [:custom_id, :result]

  @type result :: {:ok, Message.t()} | {:error, Error.t()} | :canceled | :expired

  @type t :: %__MODULE__{custom_id: String.t(), result: result()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{custom_id: json["custom_id"], result: decode_result(json["result"] || %{})}
  end

  defp decode_result(%{"type" => "succeeded", "message" => message}) do
    {:ok, Message.decode(message)}
  end

  defp decode_result(%{"type" => "errored", "error" => error}) do
    {:error, Error.from_stream_event(error)}
  end

  defp decode_result(%{"type" => "canceled"}), do: :canceled
  defp decode_result(%{"type" => "expired"}), do: :expired

  defp decode_result(json) do
    {:error, Error.stream_error("unrecognised batch result", json)}
  end
end

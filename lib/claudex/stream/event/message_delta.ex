defmodule Claudex.Stream.Event.MessageDelta do
  @moduledoc """
  Top-level changes to the message once its content is done: why it stopped
  and the final token counts.

  `usage` only carries the fields the API chose to send, so merge it into the
  usage from `message_start` rather than replacing it —
  `Claudex.Stream.Accumulator` does that for you.
  """

  alias Claudex.Usage

  defstruct [:stop_reason, :stop_sequence, :stop_details, :container, :usage]

  @type t :: %__MODULE__{
          stop_reason: String.t() | nil,
          stop_sequence: String.t() | nil,
          stop_details: map() | nil,
          container: map() | nil,
          usage: Usage.t() | nil
        }

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    delta = json["delta"] || %{}

    %__MODULE__{
      stop_reason: delta["stop_reason"],
      stop_sequence: delta["stop_sequence"],
      stop_details: delta["stop_details"],
      container: delta["container"],
      usage: decode_usage(json["usage"])
    }
  end

  defp decode_usage(nil), do: nil
  defp decode_usage(usage), do: Usage.decode(usage)
end

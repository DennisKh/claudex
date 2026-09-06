defmodule Claudex.Stream.Event.ContentBlockDelta do
  @moduledoc """
  A piece of the content block at `index`. The `delta` is a tagged tuple you
  can match on directly:

      %ContentBlockDelta{delta: {:text, chunk}} -> IO.write(chunk)

  `{:input_json, chunk}` is a fragment of a tool call's arguments — the
  fragments are only valid JSON once concatenated, which
  `Claudex.Stream.Accumulator` does for you.
  """

  defstruct [:index, :delta]

  @type delta ::
          {:text, String.t()}
          | {:input_json, String.t()}
          | {:thinking, String.t()}
          | {:signature, String.t()}
          | {:citation, map()}
          | {:unknown, map()}

  @type t :: %__MODULE__{index: non_neg_integer(), delta: delta()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{index: json["index"], delta: decode_delta(json["delta"] || %{})}
  end

  defp decode_delta(%{"type" => "text_delta", "text" => text}), do: {:text, text}

  defp decode_delta(%{"type" => "input_json_delta", "partial_json" => json}),
    do: {:input_json, json}

  defp decode_delta(%{"type" => "thinking_delta", "thinking" => thinking}),
    do: {:thinking, thinking}

  defp decode_delta(%{"type" => "signature_delta", "signature" => signature}),
    do: {:signature, signature}

  defp decode_delta(%{"type" => "citations_delta", "citation" => citation}),
    do: {:citation, citation}

  defp decode_delta(json), do: {:unknown, json}
end

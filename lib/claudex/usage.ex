defmodule Claudex.Usage do
  @moduledoc """
  Token counts for one Messages API request. `input_tokens` and
  `output_tokens` are what you're billed for; the rest breaks that down
  further (cache hits, server tool calls, and so on).

  `raw` holds the usage object exactly as it arrived, so a counter the API adds
  before Claudex models it is still readable. It's hidden from `inspect/1` to
  keep output readable.

  It arrives on `Claudex.Message`, and on the `Claudex.Stream.Event.MessageDelta`
  of a stream, where `merge/2` folds the two together.
  `Claudex.Messages.count_tokens/2` gives the input count before a request is
  sent.
  """

  @derive {Inspect, except: [:raw]}
  defstruct [
    :raw,
    :speed,
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens,
    :cache_creation,
    :server_tool_use,
    :output_tokens_details,
    :service_tier,
    :inference_geo
  ]

  @type t :: %__MODULE__{
          raw: map(),
          speed: String.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer() | nil,
          cache_read_input_tokens: non_neg_integer() | nil,
          cache_creation: map() | nil,
          server_tool_use: map() | nil,
          output_tokens_details: map() | nil,
          service_tier: String.t() | nil,
          inference_geo: String.t() | nil
        }

  @doc """
  Folds a later usage object into an earlier one, field by field.

  A streamed reply reports usage twice: `message_start` carries the input and
  cache counts, `message_delta` the output ones. Merging keeps both, replacing
  would drop the input counts, and the loss is silent.

      iex> earlier = %Claudex.Usage{input_tokens: 11, output_tokens: 1}
      iex> later = %Claudex.Usage{output_tokens: 42}
      iex> Claudex.Usage.merge(earlier, later)
      %Claudex.Usage{input_tokens: 11, output_tokens: 42}

  The counts are running totals, not increments, `message_delta` reports the
  output tokens for the reply so far, so the later value replaces the earlier
  one. Adding them together would double-count.

  It merges field by field because the later object carries fewer fields:
  `service_tier`, for one, arrives only in `message_start`. Anything the later
  object leaves `nil` keeps the earlier value.
  """
  @spec merge(t() | nil, t() | nil) :: t() | nil
  def merge(usage, nil), do: usage

  def merge(nil, %__MODULE__{} = later), do: later

  def merge(%__MODULE__{} = earlier, %__MODULE__{} = later) do
    later
    |> Map.from_struct()
    |> Enum.reduce(earlier, fn
      {_field, nil}, usage -> usage
      {field, value}, usage -> Map.put(usage, field, value)
    end)
  end

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      raw: json,
      speed: json["speed"],
      input_tokens: json["input_tokens"],
      output_tokens: json["output_tokens"],
      cache_creation_input_tokens: json["cache_creation_input_tokens"],
      cache_read_input_tokens: json["cache_read_input_tokens"],
      cache_creation: json["cache_creation"],
      server_tool_use: json["server_tool_use"],
      output_tokens_details: json["output_tokens_details"],
      service_tier: json["service_tier"],
      inference_geo: json["inference_geo"]
    }
  end
end

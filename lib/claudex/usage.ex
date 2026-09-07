defmodule Claudex.Usage do
  @moduledoc """
  Token counts for one Messages API request. `input_tokens` and
  `output_tokens` are what you're billed for; the rest breaks that down
  further (cache hits, server tool calls, and so on).

  `raw` holds the usage object exactly as it arrived, so a counter the API adds
  before Claudex models it is still readable. It's hidden from `inspect/1` to
  keep output readable.
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

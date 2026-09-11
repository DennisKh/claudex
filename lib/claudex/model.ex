defmodule Claudex.Model do
  @moduledoc """
  One model your API key can use, as the Models API describes it.
  `Claudex.Models.list/2` and `retrieve/2` return these.

  `capabilities` stays a plain map — it's a deep, fast-moving structure
  (batch, citations, thinking, structured outputs, and so on), so Claudex
  hands it to you as the API sent it.
  """

  alias Claudex.Timestamp

  defstruct [
    :id,
    :type,
    :display_name,
    :created_at,
    :max_tokens,
    :max_input_tokens,
    :capabilities
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          display_name: String.t(),
          created_at: DateTime.t() | nil,
          max_tokens: pos_integer() | nil,
          max_input_tokens: pos_integer() | nil,
          capabilities: map() | nil
        }

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      id: json["id"],
      type: json["type"],
      display_name: json["display_name"],
      created_at: Timestamp.decode(json["created_at"]),
      max_tokens: json["max_tokens"],
      max_input_tokens: json["max_input_tokens"],
      capabilities: json["capabilities"]
    }
  end
end

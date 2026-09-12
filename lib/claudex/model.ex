defmodule Claudex.Model do
  @moduledoc """
  One model your API key can use, as the Models API describes it.
  `Claudex.Models.list/2` and `retrieve/2` return these.

  `capabilities` stays a plain map — it's a deep, fast-moving structure
  (batch, citations, thinking, structured outputs, and so on), so Claudex
  hands it to you as the API sent it. `supports?/2` answers the usual question
  about it without reaching in.
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

  @doc """
  Checks whether a model supports a specific capability. Takes either a capability
  name or its full path.

      Claudex.Model.supports?(model, "image_input")
      Claudex.Model.supports?(model, ["thinking", "types", "adaptive"])

  Every node under `capabilities` carries its own `"supported"` flag, and this
  reads the one at the end of the path. A path the model doesn't have is
  `false`, so a capability the API adds later answers for models that lack it
  without raising.
  """
  @spec supports?(t(), String.t() | [String.t()]) :: boolean()
  def supports?(%__MODULE__{} = model, capability) when is_binary(capability) do
    supports?(model, [capability])
  end

  def supports?(%__MODULE__{capabilities: capabilities}, path) when is_list(path) do
    case walk(capabilities, path) do
      %{"supported" => true} -> true
      _unsupported_or_missing -> false
    end
  end

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

  defp walk(%{} = node, [key | rest]), do: walk(Map.get(node, key), rest)
  defp walk(node, []), do: node
  defp walk(_missing, _path), do: nil
end

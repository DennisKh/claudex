defmodule Claudex.Messages.Batch.RequestCounts do
  @moduledoc """
  How the requests in a batch are doing. Everything starts in `processing`;
  the other four stay zero until the whole batch ends. The five always sum to
  the number of requests you submitted.
  """

  defstruct processing: 0, succeeded: 0, errored: 0, canceled: 0, expired: 0

  @type t :: %__MODULE__{
          processing: non_neg_integer(),
          succeeded: non_neg_integer(),
          errored: non_neg_integer(),
          canceled: non_neg_integer(),
          expired: non_neg_integer()
        }

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      processing: json["processing"] || 0,
      succeeded: json["succeeded"] || 0,
      errored: json["errored"] || 0,
      canceled: json["canceled"] || 0,
      expired: json["expired"] || 0
    }
  end
end

defmodule Claudex.Messages.Batch.RequestCounts do
  @moduledoc """
  Per-status tallies for one batch: `processing`, plus the four end states a
  request can reach, `succeeded`, `errored`, `canceled` and `expired`. It
  arrives on `Claudex.Messages.Batch`.
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

defmodule Claudex.Messages.Batch do
  @moduledoc """
  One Message Batch.

  `processing_status` is `"in_progress"`, `"canceling"`, or `"ended"`. Results
  only exist once it's `"ended"` — that's when `results_url` is filled in and
  `Claudex.Messages.Batches.results/2` will work.
  """

  alias Claudex.Messages.Batch.RequestCounts
  alias Claudex.Timestamp

  defstruct [
    :id,
    :type,
    :processing_status,
    :request_counts,
    :results_url,
    :created_at,
    :expires_at,
    :ended_at,
    :archived_at,
    :cancel_initiated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          processing_status: String.t(),
          request_counts: RequestCounts.t(),
          results_url: String.t() | nil,
          created_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          cancel_initiated_at: DateTime.t() | nil
        }

  @doc "Whether processing has finished, so results are ready to collect."
  @spec ended?(t()) :: boolean()
  def ended?(%__MODULE__{processing_status: status}), do: status == "ended"

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      id: json["id"],
      type: json["type"],
      processing_status: json["processing_status"],
      request_counts: RequestCounts.decode(json["request_counts"] || %{}),
      results_url: json["results_url"],
      created_at: Timestamp.decode(json["created_at"]),
      expires_at: Timestamp.decode(json["expires_at"]),
      ended_at: Timestamp.decode(json["ended_at"]),
      archived_at: Timestamp.decode(json["archived_at"]),
      cancel_initiated_at: Timestamp.decode(json["cancel_initiated_at"])
    }
  end
end

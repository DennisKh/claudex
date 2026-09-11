defmodule Claudex.Page do
  @moduledoc """
  One page of results from a list endpoint: `Claudex.Models.list/2`,
  `Claudex.Files.list/2` and `Claudex.Messages.Batches.list/2` all return one.

  `data` holds the items. The API has two cursor styles and this struct
  carries both, so the fields the endpoint doesn't use are nil:

    * Models and Message Batches use id cursors — go forward with
      `after_id: page.last_id`, back with `before_id: page.first_id`, and
      check `has_more` to know whether there is a next page.
    * Files uses an opaque cursor — pass `page: page.next_page` to get the
      next page, and stop when `next_page` is nil.
  """

  defstruct data: [], has_more: nil, first_id: nil, last_id: nil, next_page: nil

  @type t :: t(term())

  @type t(item) :: %__MODULE__{
          data: [item],
          has_more: boolean() | nil,
          first_id: String.t() | nil,
          last_id: String.t() | nil,
          next_page: String.t() | nil
        }

  @doc false
  @spec decode(map(), (map() -> item)) :: t(item) when item: var
  def decode(json, decode_item) do
    %__MODULE__{
      data: Enum.map(json["data"] || [], decode_item),
      has_more: json["has_more"],
      first_id: json["first_id"],
      last_id: json["last_id"],
      next_page: json["next_page"]
    }
  end
end

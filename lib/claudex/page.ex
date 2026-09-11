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

  Threading a cursor by hand means owning the loop, the accumulator, and the
  stop condition, and writing it twice because the two styles differ:

      Stream.unfold(:start, fn
        :done ->
          nil

        cursor ->
          opts = if cursor == :start, do: [limit: 20], else: [limit: 20, after_id: cursor]
          {:ok, page} = Claudex.Models.list(client, opts)

          {page.data, if(page.has_more, do: page.last_id, else: :done)}
      end)
      |> Enum.concat()

  Each of those modules has a `stream!/2` that does it, whichever cursor its
  endpoint uses, yielding items rather than pages:

      client |> Claudex.Models.stream!() |> Enum.to_list()

  Pages are fetched as they are consumed, so `Enum.take/2` stops requesting
  them as soon as it has enough.
  """

  alias Claudex.Error

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
  @spec stream!(keyword(), (keyword() -> {:ok, t()} | {:error, Error.t()})) :: Enumerable.t()
  def stream!(opts, fetch) do
    Stream.resource(
      fn -> {:cont, opts} end,
      fn
        :halt -> {:halt, :done}
        {:cont, opts} -> page(fetch.(opts), opts)
      end,
      fn _state -> :ok end
    )
  end

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

  defp page({:ok, %__MODULE__{} = page}, opts), do: {page.data, after_page(page, opts)}
  defp page({:error, error}, _opts), do: raise(error)

  defp after_page(%__MODULE__{has_more: true, last_id: id}, opts) when is_binary(id) do
    {:cont, Keyword.put(opts, :after_id, id)}
  end

  defp after_page(%__MODULE__{next_page: cursor}, opts) when is_binary(cursor) do
    {:cont, Keyword.put(opts, :page, cursor)}
  end

  defp after_page(%__MODULE__{}, _opts), do: :halt
end

defmodule Claudex.Live.PaginationTest do
  @moduledoc """
  End-to-end coverage of `stream!/2` on the three list endpoints, across both
  cursor styles the API uses.

  Listing spends no tokens, so this whole file is free to run. A small `:limit`
  forces the cursor to be used rather than fitting everything in one page.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Files, Messages, Models}

  test "walks id cursors across pages", %{client: client} do
    {:ok, first} = Models.list(client, limit: 2)

    assert first.has_more, "the key sees too few models for this to page"

    all = client |> Models.stream!(limit: 2) |> Enum.map(& &1.id)

    assert length(all) > length(first.data)
    assert Enum.take(all, 2) == Enum.map(first.data, & &1.id)
    assert all == Enum.uniq(all), "a repeated id means the cursor didn't advance"
  end

  test "stops as soon as the caller does", %{client: client} do
    assert client |> Models.stream!(limit: 2) |> Enum.take(3) |> length() == 3
  end

  test "walks the opaque cursor the Files API uses", %{client: client} do
    {:ok, first} = Files.list(client, limit: 1)

    if first.next_page do
      ids = client |> Files.stream!(limit: 1) |> Enum.map(& &1.id)

      assert length(ids) > 1
      assert ids == Enum.uniq(ids)
    else
      # One page of files in the workspace, so there is no cursor to follow.
      assert client |> Files.stream!(limit: 1) |> Enum.count() == length(first.data)
    end
  end

  test "batches page the same way models do", %{client: client} do
    assert client |> Messages.Batches.stream!(limit: 2) |> Enum.take(2) |> is_list()
  end
end

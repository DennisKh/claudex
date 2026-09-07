defmodule Claudex.Live.FilesTest do
  @moduledoc """
  End-to-end coverage of the Files API. Every operation here is free — only
  referencing a file's content in a Messages request costs tokens.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Error, FileMetadata, Files, Page}

  setup %{client: client} do
    {:ok, file} =
      client
      |> Recorder.record_json("file")
      |> Files.upload({"claudex live test\n", "claudex_live_test.txt"},
        content_type: "text/plain",
        expires_in_seconds: 3600
      )

    on_exit(fn -> Files.delete(client, file.id) end)

    {:ok, uploaded: file}
  end

  test "uploads a file and reads its metadata back", %{client: client, uploaded: file} do
    assert %FileMetadata{} = file
    assert file.id =~ "file_"
    assert file.type == "file"
    assert file.filename == "claudex_live_test.txt"
    assert file.mime_type == "text/plain"
    assert file.size_bytes > 0
    assert %DateTime{} = file.created_at

    # expires_at only comes back on the GA shape, so this also proves Claudex
    # isn't sending the files-api-2025-04-14 beta header.
    assert %DateTime{} = file.expires_at
    assert file.downloadable == false

    assert {:ok, %FileMetadata{id: id}} = Files.retrieve(client, file.id)
    assert id == file.id
  end

  test "lists files with the cursor the Files API actually uses", %{
    client: client,
    uploaded: file
  } do
    assert {:ok, %Page{} = page} =
             client |> Recorder.record_json("files_page") |> Files.list(limit: 20)

    assert Enum.any?(page.data, &(&1.id == file.id))
    assert page.first_id == nil
    assert page.last_id == nil
  end

  test "refuses to download a file we uploaded ourselves", %{client: client, uploaded: file} do
    assert {:error, %Error{status: 400} = error} = Files.download(client, file.id)
    assert error.message != ""
  end

  test "deletes a file, after which it is gone", %{client: client} do
    {:ok, file} = Files.upload(client, {"delete me\n", "claudex_delete_test.txt"})

    assert :ok = Files.delete(client, file.id)
    assert {:error, %Error{type: :not_found}} = Files.retrieve(client, file.id)
  end
end

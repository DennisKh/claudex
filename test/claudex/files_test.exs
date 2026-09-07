defmodule Claudex.FilesTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, FileMetadata, Files, Page}

  @metadata %{
    "id" => "file_011CNha8iCJcU1wXNR6q4V8w",
    "type" => "file",
    "filename" => "document.pdf",
    "mime_type" => "application/pdf",
    "size_bytes" => 1_024_000,
    "created_at" => "2025-01-01T00:00:00Z",
    "downloadable" => false,
    "expires_at" => nil
  }

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  test "upload/3 posts the file as multipart and decodes the metadata" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/files"

      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "multipart/form-data"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, body})

      Req.Test.json(conn, @metadata)
    end)

    assert {:ok, %FileMetadata{} = file} =
             Files.upload(client(), {"hello there", "notes.txt"})

    assert file.id == "file_011CNha8iCJcU1wXNR6q4V8w"
    assert file.filename == "document.pdf"
    assert file.size_bytes == 1_024_000
    assert file.created_at == ~U[2025-01-01 00:00:00Z]
    assert file.downloadable == false
    assert file.expires_at == nil

    assert_received {:body, body}
    assert body =~ ~s(name="file")
    assert body =~ ~s(filename="notes.txt")
    assert body =~ "hello there"
  end

  test "upload/3 sends expires_in_seconds and an explicit content type" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, body})

      Req.Test.json(conn, @metadata)
    end)

    assert {:ok, %FileMetadata{}} =
             Files.upload(client(), {"a,b\n1,2", "data.csv"},
               content_type: "text/csv",
               expires_in_seconds: 3600
             )

    assert_received {:body, body}
    assert body =~ "text/csv"
    assert body =~ ~s(name="expires_in_seconds")
    assert body =~ "3600"
  end

  test "upload/3 reads a path and uses its basename" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "claudex_upload_test.txt")
    File.write!(path, "from disk")
    on_exit(fn -> File.rm(path) end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, body})

      Req.Test.json(conn, @metadata)
    end)

    assert {:ok, %FileMetadata{}} = Files.upload(client(), path)

    assert_received {:body, body}
    assert body =~ ~s(filename="claudex_upload_test.txt")
    assert body =~ "from disk"
  end

  test "list/2 decodes a page that pages by cursor, not by id" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"limit" => "2"}

      Req.Test.json(conn, %{"data" => [@metadata], "next_page" => "page_abc"})
    end)

    assert {:ok, %Page{} = page} = Files.list(client(), limit: 2)

    assert [%FileMetadata{id: "file_011CNha8iCJcU1wXNR6q4V8w"}] = page.data
    assert page.next_page == "page_abc"
    assert page.first_id == nil
    assert page.last_id == nil
  end

  test "retrieve/2 fetches one file's metadata" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/files/file_1"

      Req.Test.json(conn, @metadata)
    end)

    assert {:ok, %FileMetadata{type: "file"}} = Files.retrieve(client(), "file_1")
  end

  test "download/2 returns the raw bytes undecoded" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/files/file_1/content"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"not":"parsed"}))
    end)

    assert {:ok, ~s({"not":"parsed"})} = Files.download(client(), "file_1")
  end

  test "download/2 surfaces the API's refusal to download an uploaded file" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => "File is not downloadable"}
      })
    end)

    assert {:error, %Error{type: :bad_request, message: "File is not downloadable"}} =
             Files.download(client(), "file_1")
  end

  test "delete/2 returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/files/file_1"

      Req.Test.json(conn, %{"id" => "file_1", "type" => "file_deleted"})
    end)

    assert :ok = Files.delete(client(), "file_1")
  end

  test "an empty file id is rejected without making a request" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("should not have made a request") end)

    assert {:error, %Error{type: :bad_request, message: "file id can't be empty"}} =
             Files.retrieve(client(), "")

    assert {:error, %Error{type: :bad_request}} = Files.download(client(), "")
    assert {:error, %Error{type: :bad_request}} = Files.delete(client(), "")
  end
end

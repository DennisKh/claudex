defmodule Claudex.Files do
  @moduledoc """
  The Files API — upload a file once, then reference it by `file_id` in as
  many Messages requests as you like instead of re-sending the bytes.

      {:ok, file} = Claudex.Files.upload(client, "report.pdf")

      Claudex.Messages.create(client, %{
        model: "claude-opus-5",
        max_tokens: 1024,
        messages: [%{role: "user", content: [
          %{type: "document", source: %{type: "file", file_id: file.id}},
          %{type: "text", text: "Summarise this."}
        ]}]
      })

  This saves upload time and request size, not tokens — the file's content
  still enters the context window and is still billed.

  Uploaded files are visible to the whole workspace, not scoped to a user or
  conversation, so never accept a `file_id` from an untrusted source.

  `download/2` only works on files Claude created through skills or the code
  execution tool; downloading one you uploaded returns a 400.
  """

  alias Claudex.{API, Client, Error, FileMetadata, Page}

  @doc """
  Uploads a file, either from a path or as `{content, filename}`.

  ## Options

    * `:content_type` - the file's MIME type. The API detects it from the
      content when you leave this out.
    * `:expires_in_seconds` - delete the file automatically after this long.
      Between 3600 (an hour) and 7_776_000 (90 days); without it the file
      lives until you delete it.

  Raises if a path can't be read — that's a problem with your filesystem
  rather than with the API.
  """
  @spec upload(Client.t(), Path.t() | {iodata(), String.t()}) ::
          {:ok, FileMetadata.t()} | {:error, Error.t()}
  @spec upload(Client.t(), Path.t() | {iodata(), String.t()}, keyword()) ::
          {:ok, FileMetadata.t()} | {:error, Error.t()}
  def upload(client, file, opts \\ [])

  def upload(%Client{} = client, path, opts) when is_binary(path) do
    upload(client, {File.read!(path), Path.basename(path)}, opts)
  end

  def upload(%Client{} = client, {content, filename}, opts) do
    fields = [{:file, {content, part_options(filename, opts)}}] ++ expiry_field(opts)

    with {:ok, body} <-
           API.request(client, method: :post, url: "/v1/files", form_multipart: fields) do
      {:ok, FileMetadata.decode(body)}
    end
  end

  @doc """
  Lists the files in your workspace, newest first.

  ## Options

    * `:limit` - how many per page, 1 to 1000. Defaults to 20.
    * `:page` - the `next_page` cursor from a previous page.

  Files paginate with an opaque cursor rather than ids: pass
  `page: page.next_page` for the next page, and stop when it's nil.
  """
  @spec list(Client.t()) :: {:ok, Page.t(FileMetadata.t())} | {:error, Error.t()}
  @spec list(Client.t(), keyword()) :: {:ok, Page.t(FileMetadata.t())} | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, body} <- API.get(client, "/v1/files", opts) do
      {:ok, Page.decode(body, &FileMetadata.decode/1)}
    end
  end

  @doc "Looks up one file's metadata."
  @spec retrieve(Client.t(), String.t()) :: {:ok, FileMetadata.t()} | {:error, Error.t()}
  def retrieve(%Client{} = client, file_id) do
    with :ok <- validate_id(file_id),
         {:ok, body} <- API.get(client, path(file_id)) do
      {:ok, FileMetadata.decode(body)}
    end
  end

  @doc """
  Downloads a file's contents.

  Only works on files Claude created — check `downloadable` on the metadata
  first. Returns the whole file in memory, so mind the 500 MB ceiling.
  """
  @spec download(Client.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def download(%Client{} = client, file_id) do
    with :ok <- validate_id(file_id),
         {:ok, body} <-
           API.request(client, method: :get, url: path(file_id) <> "/content", decode_body: false) do
      if is_binary(body) do
        {:ok, body}
      else
        {:error, Error.stream_error("the file download wasn't returned as bytes", body)}
      end
    end
  end

  @doc "Deletes a file. Deleted files can't be recovered."
  @spec delete(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%Client{} = client, file_id) do
    with :ok <- validate_id(file_id),
         {:ok, _body} <- API.delete(client, path(file_id)) do
      :ok
    end
  end

  defp path(file_id), do: "/v1/files/" <> URI.encode(file_id, &URI.char_unreserved?/1)

  defp part_options(filename, opts) do
    case Keyword.fetch(opts, :content_type) do
      {:ok, content_type} -> [filename: filename, content_type: content_type]
      :error -> [filename: filename]
    end
  end

  defp expiry_field(opts) do
    case Keyword.fetch(opts, :expires_in_seconds) do
      {:ok, seconds} -> [{:expires_in_seconds, to_string(seconds)}]
      :error -> []
    end
  end

  defp validate_id(file_id) when file_id in [nil, ""] do
    {:error, %Error{type: :bad_request, message: "file id can't be empty"}}
  end

  defp validate_id(_file_id), do: :ok
end

defmodule Claudex.Messages.Batches do
  @moduledoc """
  The Message Batches API — send up to 100,000 Messages requests at once for
  asynchronous processing, at half the token cost.

  The flow is submit, check back, collect:

      requests = [
        %{
          custom_id: "ticket-1",
          params: %{
            model: "claude-opus-5",
            max_tokens: 1024,
            messages: [%{role: "user", content: "..."}]
          }
        }
      ]

      {:ok, batch} = Batches.create(client, requests)

      # later, from a job runner
      {:ok, batch} = Batches.retrieve(client, batch.id)

      if Claudex.Messages.Batch.ended?(batch) do
        {:ok, results} = Batches.results(client, batch.id)
        Enum.each(results, &handle/1)
      end

  Claudex doesn't poll for you. A batch has 24 hours to finish, so check on it
  from your app's job runner with the batch id persisted.

  Each request's `params` are validated asynchronously, and a validation error
  arrives with that request's result once the batch has ended — so a batch
  containing a request the Messages API would reject outright is still
  accepted. Check a request's shape against `Claudex.Messages.create/2` before
  batching a lot of them.

  Results come back in whatever order the requests finished, so match them to
  your requests by `custom_id`. `results/2` streams them, so a batch far too
  big to hold in memory is still fine to walk.
  """

  alias Claudex.{API, ChunkStream, Client, Error, JSONL, Message, Page, Tool}
  alias Claudex.Messages.{Batch, BatchResult}

  @doc """
  Submits a batch.

  Each request is a map with a `:custom_id` — 1 to 64 characters of letters,
  digits, hyphens, and underscores, unique within the batch — and `:params`,
  which takes exactly what `Claudex.Messages.create/2` takes. `:tools` in
  those params accepts a module the same way, and `max_tokens` must be at
  least 1.

  ## Examples

      requests = [
        %{
          custom_id: "ticket-1",
          params: %{
            model: "claude-opus-5",
            max_tokens: 1024,
            messages: [Claudex.Message.user("Summarise: the printer is offline")]
          }
        },
        %{
          custom_id: "ticket-2",
          params: %{
            model: "claude-opus-5",
            max_tokens: 1024,
            messages: [Claudex.Message.user("Summarise: billed twice in March")]
          }
        }
      ]

      {:ok, batch} = Claudex.Messages.Batches.create(client, requests)
      batch.id
      #=> "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d"

  """
  @spec create(Client.t(), [map()]) :: {:ok, Batch.t()} | {:error, Error.t()}
  def create(%Client{} = client, requests) when is_list(requests) do
    body = %{requests: Enum.map(requests, &normalize_request/1)}

    with {:ok, response} <- API.post(client, "/v1/messages/batches", body) do
      {:ok, Batch.decode(response)}
    end
  end

  @doc "Looks up a batch. This is the endpoint to poll for completion."
  @spec retrieve(Client.t(), String.t()) :: {:ok, Batch.t()} | {:error, Error.t()}
  def retrieve(%Client{} = client, batch_id) do
    with :ok <- validate_id(batch_id),
         {:ok, response} <- API.get(client, path(batch_id)) do
      {:ok, Batch.decode(response)}
    end
  end

  @doc """
  Lists your batches, newest first.

  Takes `:limit`, `:after_id`, and `:before_id` — the same id cursors
  `Claudex.Models.list/2` uses.
  """
  @spec list(Client.t()) :: {:ok, Page.t(Batch.t())} | {:error, Error.t()}
  @spec list(Client.t(), keyword()) :: {:ok, Page.t(Batch.t())} | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, response} <- API.get(client, "/v1/messages/batches", opts) do
      {:ok, Page.decode(response, &Batch.decode/1)}
    end
  end

  @doc """
  Asks for a batch to be canceled.

  Cancellation isn't immediate: the batch moves to `"canceling"`, and requests
  already in flight may still finish, so expect a mix of canceled and
  succeeded results.
  """
  @spec cancel(Client.t(), String.t()) :: {:ok, Batch.t()} | {:error, Error.t()}
  def cancel(%Client{} = client, batch_id) do
    with :ok <- validate_id(batch_id),
         {:ok, response} <- API.post(client, path(batch_id) <> "/cancel", %{}) do
      {:ok, Batch.decode(response)}
    end
  end

  @doc "Deletes a batch. It must have finished processing first."
  @spec delete(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%Client{} = client, batch_id) do
    with :ok <- validate_id(batch_id),
         {:ok, _response} <- API.delete(client, path(batch_id)) do
      :ok
    end
  end

  @doc """
  Streams a finished batch's results as `Claudex.Messages.BatchResult` structs.

  Returns `{:error, %Claudex.Error{}}` if the batch hasn't ended yet — check
  `Claudex.Messages.Batch.ended?/1` first, or just match on the error and try
  again later.

  The stream reads the results file as it goes rather than pulling it all into
  memory, decoding one line at a time, so enumerating it lazily
  (`Stream.filter/2`, `Enum.reduce/3`) keeps a 100,000-request batch
  manageable. Enumerating raises `Claudex.Error` if
  the download fails part-way.
  """
  @spec results(Client.t(), String.t()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def results(%Client{} = client, batch_id) do
    with {:ok, batch} <- retrieve(client, batch_id) do
      stream_results(client, batch)
    end
  end

  defp stream_results(_client, %Batch{results_url: nil} = batch) do
    {:error,
     %Error{
       type: :bad_request,
       message:
         "batch #{batch.id} has no results yet — processing_status is #{batch.processing_status}"
     }}
  end

  defp stream_results(client, %Batch{results_url: results_url}) do
    stream =
      client
      |> ChunkStream.stream(method: :get, url: results_url)
      |> Stream.transform(&JSONL.new/0, &decode_chunk/2, &flush/1, fn _decoder -> :ok end)
      |> Stream.map(&decode_line/1)

    {:ok, stream}
  end

  defp decode_chunk(chunk, decoder) do
    JSONL.decode(decoder, chunk)
  end

  defp flush(decoder), do: JSONL.flush(decoder)

  defp decode_line(line) do
    case JSON.decode(line) do
      {:ok, json} when is_map(json) -> BatchResult.decode(json)
      _not_an_object -> raise Error.stream_error("a batch result line wasn't a JSON object", line)
    end
  end

  defp normalize_request(%{params: params} = request) do
    %{request | params: params |> Map.new() |> normalize_tools() |> normalize_messages()}
  end

  defp normalize_request(request), do: request

  defp normalize_tools(%{tools: tools} = params), do: %{params | tools: Tool.list(tools)}
  defp normalize_tools(params), do: params

  defp normalize_messages(%{messages: messages} = params) when is_list(messages) do
    %{params | messages: Enum.map(messages, &Message.to_param/1)}
  end

  defp normalize_messages(params), do: params

  defp path(batch_id) do
    "/v1/messages/batches/" <> URI.encode(batch_id, &URI.char_unreserved?/1)
  end

  defp validate_id(batch_id) when batch_id in [nil, ""] do
    {:error, %Error{type: :bad_request, message: "batch id can't be empty"}}
  end

  defp validate_id(_batch_id), do: :ok
end

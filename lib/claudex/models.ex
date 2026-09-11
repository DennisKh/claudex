defmodule Claudex.Models do
  @moduledoc """
  The Models API — find out which models your key can use and what each one
  supports.

  Useful for resolving an alias like `"claude-opus-latest"` to the model id it
  currently points at. Each entry is a `Claudex.Model`, and `list/2` returns a
  `Claudex.Page` of them.
  """

  alias Claudex.{API, Client, Error, Model, Page}

  @doc """
  Lists the models available to your key, newest first.

  Options become query parameters. The API defines three:

    * `:limit` - how many to return per page, 1 to 1000. Defaults to 20.
    * `:after_id` - return the page right after this model id.
    * `:before_id` - return the page right before this model id.

  The result is one page. Check `has_more` and pass `after_id: page.last_id`
  to get the next one.
  """
  @spec list(Client.t()) :: {:ok, Page.t(Model.t())} | {:error, Error.t()}
  @spec list(Client.t(), keyword()) :: {:ok, Page.t(Model.t())} | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, body} <- API.get(client, "/v1/models", opts) do
      {:ok, Page.decode(body, &Model.decode/1)}
    end
  end

  @doc """
  Every model your key can use, as one lazy stream.

      client
      |> Claudex.Models.stream!()
      |> Enum.filter(&get_in(&1.capabilities, ["code_execution", "supported"]))
      |> Enum.map(& &1.id)
      #=> ["claude-opus-5", "claude-sonnet-5", ...]

  Picking a model by what it supports keeps working as models come and go,
  where a hardcoded list goes stale.

  Pages are fetched as you consume them, so taking the first few costs one
  request. Takes the same options as `list/2`, minus the cursor it threads
  itself. Enumerating raises `Claudex.Error` if a request fails.
  """
  @spec stream!(Client.t()) :: Enumerable.t()
  @spec stream!(Client.t(), keyword()) :: Enumerable.t()
  def stream!(%Client{} = client, opts \\ []) do
    Page.stream!(opts, &list(client, &1))
  end

  @doc """
  Looks up one model by id or alias.

      {:ok, model} = Claudex.Models.retrieve(client, "claude-opus-5")
  """
  @spec retrieve(Client.t(), String.t()) :: {:ok, Model.t()} | {:error, Error.t()}
  def retrieve(%Client{} = _client, model_id) when model_id in [nil, ""] do
    {:error, %Error{type: :bad_request, message: "model id can't be empty"}}
  end

  def retrieve(%Client{} = client, model_id) do
    path = "/v1/models/" <> URI.encode(model_id, &URI.char_unreserved?/1)

    with {:ok, body} <- API.get(client, path) do
      {:ok, Model.decode(body)}
    end
  end
end

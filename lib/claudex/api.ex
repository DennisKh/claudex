defmodule Claudex.API do
  @moduledoc false

  alias Claudex.{Client, Error, Tracing}
  alias Claudex.Tracing.Attributes

  @doc """
  Runs one request against the client and reduces the result to a tagged tuple:
  the decoded body on a 2xx, a `Claudex.Error` on anything else, including a
  transport failure.

  `request_options` reach `Req.request/2` unchanged, so any Req option works.
  `:method` is the only one required, and a call without it raises. The rest
  are whatever the endpoint needs: `:url`, `:params`, `:json`,
  `:form_multipart` and `:decode_body` are the ones used here.

  `:method`, `:url` and a `:model` inside the `:json` body are also read for the
  telemetry metadata and the span, so an endpoint that names its model in the
  body gets it recorded without passing it twice.

  `opts` are Claudex's own and reach neither Req nor the telemetry metadata.
  A caller passing its own options through sends the whole list; anything but
  the key below is ignored.

  ## Options

    * `:session` - names the conversation the request belongs to, as
      `t:Claudex.Tracing.session_option/0` describes.

  Wraps the call in the `[:claudex, :request, ...]` telemetry events and an
  OpenTelemetry span, which is a no-op unless the app traces.
  """
  @spec request(Client.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  @spec request(Client.t(), keyword(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def request(%Client{} = client, request_options, opts \\ []) do
    metadata =
      %{
        method: Keyword.fetch!(request_options, :method),
        path: Keyword.get(request_options, :url)
      }
      |> put_model(request_options)

    Tracing.span(
      fn -> Attributes.request(metadata, request_options, opts) end,
      fn span -> traced(client, request_options, metadata, span) end
    )
  end

  defp traced(client, options, metadata, span) do
    started = System.monotonic_time()

    :telemetry.execute(
      [:claudex, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      raw = Req.request(client.req, options)

      :telemetry.execute(
        [:claudex, :request, :stop],
        %{duration: System.monotonic_time() - started},
        Map.merge(metadata, response_metadata(raw))
      )

      record_response(raw, span)

      handle(raw)
    catch
      kind, reason ->
        :telemetry.execute(
          [:claudex, :request, :exception],
          %{duration: System.monotonic_time() - started},
          Map.merge(metadata, %{kind: kind, error: error_module(kind, reason, __STACKTRACE__)})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "GETs `url`, with `params` as the query string."
  @spec get(Client.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  @spec get(Client.t(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(%Client{} = client, url, params \\ []) do
    request(client, method: :get, url: url, params: params)
  end

  @doc "POSTs `body` to `url` as JSON. `opts` are `request/3`'s."
  @spec post(Client.t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  @spec post(Client.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def post(%Client{} = client, url, body, opts \\ []) do
    request(client, [method: :post, url: url, json: body], opts)
  end

  @doc "DELETEs `url`."
  @spec delete(Client.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def delete(%Client{} = client, url) do
    request(client, method: :delete, url: url)
  end

  @doc false
  @spec put_model(map(), keyword()) :: map()
  def put_model(metadata, options) do
    case Keyword.get(options, :json) do
      %{} = body -> maybe_put_model(metadata, body[:model] || body["model"])
      _not_a_body -> metadata
    end
  end

  @doc false
  @spec request_id(Req.Response.t()) :: String.t() | nil
  def request_id(response) do
    case Req.Response.get_header(response, "request-id") do
      [request_id | _rest] -> request_id
      [] -> nil
    end
  end

  defp record_response(_raw, :untraced), do: :ok

  defp record_response({:ok, %Req.Response{status: status, body: body}}, span) do
    Tracing.set_attributes(span, Attributes.response(body, status))

    if status not in 200..299, do: Tracing.set_error(span, Attributes.error_message(body, status))
  end

  defp record_response({:error, exception}, span) do
    Tracing.set_error(span, inspect(exception.__struct__))
  end

  defp error_module(:error, reason, stacktrace) do
    :error |> Exception.normalize(reason, stacktrace) |> Map.fetch!(:__struct__)
  end

  defp error_module(_kind, _reason, _stacktrace), do: nil

  defp maybe_put_model(metadata, model) when is_binary(model),
    do: Map.put(metadata, :model, model)

  defp maybe_put_model(metadata, _model), do: metadata

  defp response_metadata({:ok, %Req.Response{} = response}) do
    %{status: response.status, request_id: request_id(response)}
    |> Map.merge(usage(response.body))
  end

  defp response_metadata({:error, exception}) do
    %{status: nil, error: exception.__struct__}
  end

  defp usage(%{"usage" => %{} = usage}) do
    %{input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"]}
    |> put_present(:cache_creation_input_tokens, usage["cache_creation_input_tokens"])
    |> put_present(:cache_read_input_tokens, usage["cache_read_input_tokens"])
  end

  defp usage(_body), do: %{}

  defp put_present(metadata, _key, nil), do: metadata
  defp put_present(metadata, key, value), do: Map.put(metadata, key, value)

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle({:ok, %Req.Response{status: status, body: body} = response}) do
    {:error, Error.from_response(status, body, request_id(response))}
  end

  defp handle({:error, exception}), do: {:error, Error.from_transport(exception)}
end

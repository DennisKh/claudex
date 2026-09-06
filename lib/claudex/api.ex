defmodule Claudex.API do
  @moduledoc false

  alias Claudex.{Client, Error}

  @spec request(Client.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def request(%Client{} = client, options) do
    metadata =
      %{method: Keyword.get(options, :method, :get), path: Keyword.get(options, :url)}
      |> put_model(options)

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

      handle(raw)
    catch
      kind, reason ->
        # Deliberately not `:telemetry.span/3`: it puts `:reason` and
        # `:stacktrace` in the exception event's metadata, and a stacktrace
        # frame from inside a Req step holds the whole `%Req.Request{}` — the
        # `x-api-key` header and the JSON body with it. Only the kind and the
        # exception's module go out.
        :telemetry.execute(
          [:claudex, :request, :exception],
          %{duration: System.monotonic_time() - started},
          Map.merge(metadata, %{kind: kind, error: error_module(kind, reason, __STACKTRACE__)})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # `catch :error, reason` hands back the raw Erlang term, so normalizing is
  # what turns `:function_clause` into `FunctionClauseError`. Only the module
  # is taken — the normalized struct holds the call's arguments.
  defp error_module(:error, reason, stacktrace) do
    :error |> Exception.normalize(reason, stacktrace) |> Map.fetch!(:__struct__)
  end

  defp error_module(_kind, _reason, _stacktrace), do: nil

  # The model is the one thing in the body worth reporting: it decides cost and
  # behaviour, and a log line without it can't be compared against another.
  defp put_model(metadata, options) do
    case Keyword.get(options, :json) do
      %{} = body -> maybe_put_model(metadata, body[:model] || body["model"])
      _not_a_body -> metadata
    end
  end

  defp maybe_put_model(metadata, model) when is_binary(model),
    do: Map.put(metadata, :model, model)

  defp maybe_put_model(metadata, _model), do: metadata

  # Metadata only: status, request id, token counts. Never the body — logs
  # travel further than conversations should.
  defp response_metadata({:ok, %Req.Response{} = response}) do
    %{status: response.status, request_id: request_id(response)}
    |> Map.merge(usage(response.body))
  end

  defp response_metadata({:error, exception}) do
    %{status: nil, error: exception.__struct__}
  end

  defp request_id(response) do
    case Req.Response.get_header(response, "request-id") do
      [request_id | _rest] -> request_id
      [] -> nil
    end
  end

  defp usage(%{"usage" => %{} = usage}) do
    %{input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"]}
  end

  defp usage(_body), do: %{}

  @spec get(Client.t(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(%Client{} = client, url, params \\ []) do
    request(client, method: :get, url: url, params: params)
  end

  @spec post(Client.t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def post(%Client{} = client, url, body) do
    request(client, method: :post, url: url, json: body)
  end

  @spec delete(Client.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def delete(%Client{} = client, url) do
    request(client, method: :delete, url: url)
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) do
    {:error, Error.from_response(status, body)}
  end

  defp handle({:error, exception}), do: {:error, Error.from_transport(exception)}
end

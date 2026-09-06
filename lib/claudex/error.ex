defmodule Claudex.Error do
  @moduledoc """
  An error from the Claude API, or from trying to reach it.

  `:type` mirrors the error types the API documents — `:billing` for 402,
  `:timeout` for a 504 as well as for a client-side timeout, and so on.
  `:error_type` is the API's own string (`"invalid_request_error"`), finer
  grained than the status and extensible by the API, so reach for it when
  `:type` isn't specific enough. Match on it to handle specific cases:

      case Claudex.Messages.create(client, params) do
        {:ok, message} -> message
        {:error, %Claudex.Error{type: :rate_limit}} -> :retry_later
        {:error, error} -> raise error
      end
  """

  @status_types %{
    400 => :bad_request,
    401 => :authentication,
    402 => :billing,
    403 => :permission_denied,
    404 => :not_found,
    409 => :conflict,
    413 => :request_too_large,
    422 => :unprocessable_entity,
    429 => :rate_limit,
    504 => :timeout,
    529 => :overloaded
  }

  @error_types %{
    "invalid_request_error" => :bad_request,
    "authentication_error" => :authentication,
    "billing_error" => :billing,
    "permission_error" => :permission_denied,
    "not_found_error" => :not_found,
    "rate_limit_error" => :rate_limit,
    "timeout_error" => :timeout,
    "overloaded_error" => :overloaded,
    "api_error" => :internal_server
  }

  defexception [:type, :error_type, :message, :status, :request_id, :body]

  @type type ::
          :bad_request
          | :authentication
          | :permission_denied
          | :not_found
          | :conflict
          | :request_too_large
          | :unprocessable_entity
          | :rate_limit
          | :overloaded
          | :billing
          | :internal_server
          | :api_status
          | :connection
          | :timeout
          | :stream

  @type t :: %__MODULE__{
          type: type(),
          error_type: String.t() | nil,
          message: String.t(),
          status: pos_integer() | nil,
          request_id: String.t() | nil,
          body: term()
        }

  @doc """
  Builds an error from an HTTP response: a status code and its body.

  The body may arrive undecoded — a download asks Req not to parse what it
  fetches — so a JSON error body is decoded here rather than lost.
  """
  @spec from_response(pos_integer(), map() | binary() | nil) :: t()
  def from_response(status, body) do
    body = decode_body(body)
    error_type = error_type_from_body(body)

    %__MODULE__{
      type: known_type(error_type) || type_for_status(status),
      error_type: error_type,
      message: message_from_body(body, status),
      status: status,
      request_id: request_id_from_body(body),
      body: body
    }
  end

  @doc """
  Builds an error from an `error` event the API sent part-way through a
  stream. There's no HTTP status on one of these, so the type comes from the
  event's own error type.
  """

  @spec from_stream_event(map()) :: t()
  def from_stream_event(body) do
    error = error_object(body)

    %__MODULE__{
      type: type_for_error(error["type"]),
      error_type: error["type"],
      message: error["message"] || "the API ended the stream with an error",
      request_id: request_id_from_body(body),
      body: body
    }
  end

  @doc """
  Builds an error for a stream that didn't hold up its end of the protocol —
  malformed event data, or a reply that ended before it began.
  """

  @spec stream_error(String.t()) :: t()
  @spec stream_error(String.t(), term()) :: t()
  def stream_error(message, body \\ nil) do
    %__MODULE__{type: :stream, message: message, body: body}
  end

  @doc "Builds an error for a request that never got a response (timeout, connection failure)."
  @spec from_transport(Exception.t()) :: t()
  def from_transport(%{reason: :timeout} = exception) do
    %__MODULE__{type: :timeout, message: Exception.message(exception)}
  end

  def from_transport(exception) do
    %__MODULE__{type: :connection, message: Exception.message(exception)}
  end

  defp error_type_from_body(%{"error" => %{"type" => error_type}}) when is_binary(error_type) do
    error_type
  end

  defp error_type_from_body(_body), do: nil

  defp error_object(%{"error" => %{} = error}), do: error
  defp error_object(_body), do: %{}

  defp known_type(nil), do: nil

  defp known_type(error_type) do
    case type_for_error(error_type) do
      :api_status -> nil
      type -> type
    end
  end

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, json} when is_map(json) -> json
      _not_an_object -> body
    end
  end

  defp decode_body(body), do: body

  for {error_type, type} <- @error_types do
    defp type_for_error(unquote(error_type)), do: unquote(type)
  end

  defp type_for_error(_error_type), do: :api_status

  for {status, type} <- @status_types do
    defp type_for_status(unquote(status)), do: unquote(type)
  end

  defp type_for_status(status) when status >= 500, do: :internal_server
  defp type_for_status(_status), do: :api_status

  defp message_from_body(%{"error" => %{"message" => message}}, _status), do: message

  defp message_from_body(_body, status), do: "request failed with status #{status}"

  defp request_id_from_body(%{"request_id" => request_id}), do: request_id

  defp request_id_from_body(_body), do: nil
end

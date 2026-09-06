defmodule Claudex.Error do
  @moduledoc """
  An error from the Claude API, or from trying to reach it.

  `:type` mirrors the error types the API documents — `:billing` for 402,
  `:timeout` for a 504 as well as for a client-side timeout, and so on.
  `:error_type` is the API's own string (`"invalid_request_error"`), finer
  grained than the status and extensible by the API, so reach for it when
  `:type` isn't specific enough. Match
  on it to handle specific cases:

      case Claudex.Messages.create(client, params) do
        {:ok, message} -> message
        {:error, %Claudex.Error{type: :rate_limit}} -> :retry_later
        {:error, error} -> raise error
      end
  """

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

  defp error_type_from_body(%{"error" => %{"type" => error_type}}) when is_binary(error_type) do
    error_type
  end

  defp error_type_from_body(_body), do: nil

  # An unrecognised string falls back to the status, which is coarser but
  # right, rather than to `:api_status`, which says less than the status did.
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

  @doc """
  Builds an error from an `error` event the API sent part-way through a
  stream. There's no HTTP status on one of these, so the type comes from the
  event's own error type.
  """
  @spec from_stream_event(map()) :: t()
  def from_stream_event(%{"error" => %{"type" => type} = error} = body) do
    %__MODULE__{
      type: type_for_error(type),
      error_type: type,
      message: error["message"] || "the API ended the stream with an error",
      request_id: request_id_from_body(body),
      body: body
    }
  end

  def from_stream_event(body) do
    %__MODULE__{
      type: :api_status,
      message: "the API ended the stream with an error",
      request_id: request_id_from_body(body),
      body: body
    }
  end

  @doc """
  Builds an error for a stream that didn't hold up its end of the protocol —
  malformed event data, or a reply that ended before it began.
  """
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

  defp type_for_error("invalid_request_error"), do: :bad_request
  defp type_for_error("authentication_error"), do: :authentication
  defp type_for_error("permission_error"), do: :permission_denied
  defp type_for_error("not_found_error"), do: :not_found
  defp type_for_error("billing_error"), do: :billing
  defp type_for_error("rate_limit_error"), do: :rate_limit
  defp type_for_error("timeout_error"), do: :timeout
  defp type_for_error("overloaded_error"), do: :overloaded
  defp type_for_error("api_error"), do: :internal_server
  defp type_for_error(_type), do: :api_status

  defp type_for_status(400), do: :bad_request
  defp type_for_status(401), do: :authentication
  defp type_for_status(402), do: :billing
  defp type_for_status(403), do: :permission_denied
  defp type_for_status(404), do: :not_found
  defp type_for_status(409), do: :conflict
  defp type_for_status(413), do: :request_too_large
  defp type_for_status(422), do: :unprocessable_entity
  defp type_for_status(429), do: :rate_limit
  defp type_for_status(504), do: :timeout
  defp type_for_status(529), do: :overloaded
  defp type_for_status(status) when status >= 500, do: :internal_server
  defp type_for_status(_status), do: :api_status

  defp message_from_body(%{"error" => %{"message" => message}}, _status), do: message
  defp message_from_body(_body, status), do: "request failed with status #{status}"

  defp request_id_from_body(%{"request_id" => request_id}), do: request_id
  defp request_id_from_body(_body), do: nil
end

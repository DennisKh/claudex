defmodule Claudex.ErrorTest do
  use ExUnit.Case, async: true

  alias Claudex.Error

  test "from_response/2 classifies known status codes" do
    mapping = %{
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
      529 => :overloaded,
      500 => :internal_server,
      503 => :internal_server
    }

    for {status, type} <- mapping do
      assert %Error{type: ^type} = Error.from_response(status, nil)
    end
  end

  test "from_response/3 classifies every error type string the API documents" do
    mapping = %{
      "invalid_request_error" => :bad_request,
      "authentication_error" => :authentication,
      "billing_error" => :billing,
      "permission_error" => :permission_denied,
      "not_found_error" => :not_found,
      "conflict_error" => :conflict,
      "request_too_large" => :request_too_large,
      "rate_limit_error" => :rate_limit,
      "timeout_error" => :timeout,
      "overloaded_error" => :overloaded,
      "api_error" => :internal_server
    }

    # Status 418 so the type can only come from the body: a string the map
    # misses would fall through to :api_status.
    for {error_type, type} <- mapping do
      body = %{"error" => %{"type" => error_type, "message" => "nope"}}

      assert %Error{type: ^type} = Error.from_response(418, body)
    end
  end

  test "from_response/3 takes the request id from the header when the body has none" do
    error = Error.from_response(500, "<html>gateway</html>", "req_from_header")

    assert error.request_id == "req_from_header"
  end

  test "from_response/3 prefers the body's request id over the header" do
    body = %{
      "error" => %{"type" => "not_found_error", "message" => "nope"},
      "request_id" => "req_body"
    }

    assert %Error{request_id: "req_body"} = Error.from_response(404, body, "req_header")
  end

  test "from_response/2 falls back to :api_status for an unmapped status" do
    assert %Error{type: :api_status} = Error.from_response(418, nil)
  end

  test "from_response/2 reads the message and request_id from the API error body" do
    body = %{
      "type" => "error",
      "error" => %{"type" => "invalid_request_error", "message" => "max_tokens is required"},
      "request_id" => "req_123"
    }

    error = Error.from_response(400, body)

    assert error.message == "max_tokens is required"
    assert error.request_id == "req_123"
    assert error.body == body
  end

  test "from_response/2 falls back to a generic message without an error body" do
    error = Error.from_response(500, nil)

    assert error.message == "request failed with status 500"
  end

  test "from_transport/1 classifies a timeout" do
    exception = %Req.TransportError{reason: :timeout}

    assert %Error{type: :timeout} = Error.from_transport(exception)
  end

  test "from_transport/1 classifies other transport failures as :connection" do
    exception = %Req.TransportError{reason: :econnrefused}

    assert %Error{type: :connection} = Error.from_transport(exception)
  end

  test "is a proper exception" do
    error = Error.from_response(429, nil)

    assert Exception.message(error) == "request failed with status 429"
  end

  test "from_response/2 keeps the API's own error type string" do
    body = %{
      "type" => "error",
      "error" => %{"type" => "invalid_request_error", "message" => "nope"}
    }

    assert %Error{type: :bad_request, error_type: "invalid_request_error"} =
             Error.from_response(400, body)
  end

  test "from_response/2 prefers the body's type over the status when they differ" do
    body = %{"type" => "error", "error" => %{"type" => "billing_error", "message" => "nope"}}

    # 400 alone would say :bad_request; the body is more specific.
    assert %Error{type: :billing, error_type: "billing_error"} = Error.from_response(400, body)
  end

  test "from_response/2 falls back to the status for a type string it doesn't know" do
    body = %{"type" => "error", "error" => %{"type" => "brand_new_error", "message" => "nope"}}

    assert %Error{type: :not_found, error_type: "brand_new_error"} =
             Error.from_response(404, body)
  end

  test "from_stream_event/1 keeps the type string too" do
    body = %{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "busy"}}

    assert %Error{type: :overloaded, error_type: "overloaded_error"} =
             Error.from_stream_event(body)
  end

  test "from_stream_event/1 survives an error field that isn't an object" do
    body = %{"type" => "error", "error" => "boom"}

    assert %Error{type: :api_status, error_type: nil, message: message} =
             Error.from_stream_event(body)

    assert message =~ "ended the stream with an error"
  end
end

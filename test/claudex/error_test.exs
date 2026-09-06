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

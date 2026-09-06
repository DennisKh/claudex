defmodule Claudex.Stream.EventTest do
  use ExUnit.Case, async: true

  alias Claudex.ContentBlock
  alias Claudex.Error
  alias Claudex.Stream.Event
  alias Claudex.Stream.SSE

  defp sse(name, data), do: %SSE.Event{name: name, data: data}

  test "from_sse/1 decodes message_start into the message shell" do
    data =
      ~s({"type":"message_start","message":{"id":"msg_1","role":"assistant","model":"claude-opus-5","content":[],"usage":{"input_tokens":10,"output_tokens":1}}})

    assert {:ok, %Event.MessageStart{message: message}} =
             Event.from_sse(sse("message_start", data))

    assert message.id == "msg_1"
    assert message.usage.input_tokens == 10
  end

  test "from_sse/1 decodes a content block start into a typed block" do
    data = ~s({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}})

    assert {:ok, %Event.ContentBlockStart{index: 0, content_block: %ContentBlock.Text{}}} =
             Event.from_sse(sse("content_block_start", data))
  end

  test "from_sse/1 tags each delta kind" do
    deltas = %{
      ~s({"type":"text_delta","text":"Hi"}) => {:text, "Hi"},
      ~s({"type":"input_json_delta","partial_json":"{\\"a\\":"}) => {:input_json, ~s({"a":)},
      ~s({"type":"thinking_delta","thinking":"hmm"}) => {:thinking, "hmm"},
      ~s({"type":"signature_delta","signature":"sig"}) => {:signature, "sig"},
      ~s({"type":"citations_delta","citation":{"type":"page_location"}}) =>
        {:citation, %{"type" => "page_location"}}
    }

    for {delta, expected} <- deltas do
      data = ~s({"type":"content_block_delta","index":0,"delta":#{delta}})

      assert {:ok, %Event.ContentBlockDelta{index: 0, delta: ^expected}} =
               Event.from_sse(sse("content_block_delta", data))
    end
  end

  test "from_sse/1 tags a delta type it doesn't know as :unknown" do
    data = ~s({"type":"content_block_delta","index":0,"delta":{"type":"future_delta","x":1}})

    assert {:ok, %Event.ContentBlockDelta{delta: {:unknown, %{"type" => "future_delta"}}}} =
             Event.from_sse(sse("content_block_delta", data))
  end

  test "from_sse/1 decodes message_delta including stop_details and usage" do
    data =
      ~s({"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null,"stop_details":{"type":"refusal"}},"usage":{"output_tokens":15}})

    assert {:ok, %Event.MessageDelta{} = event} = Event.from_sse(sse("message_delta", data))
    assert event.stop_reason == "end_turn"
    assert event.stop_details == %{"type" => "refusal"}
    assert event.usage.output_tokens == 15
    assert event.usage.input_tokens == nil
  end

  test "from_sse/1 decodes message_stop" do
    assert {:ok, %Event.MessageStop{}} =
             Event.from_sse(sse("message_stop", ~s({"type":"message_stop"})))
  end

  test "from_sse/1 ignores ping events" do
    assert Event.from_sse(sse("ping", ~s({"type": "ping"}))) == :ignore
  end

  test "from_sse/1 turns an error event into a typed error" do
    data =
      ~s({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_1"})

    assert {:error, %Error{} = error} = Event.from_sse(sse("error", data))
    assert error.type == :overloaded
    assert error.message == "Overloaded"
    assert error.request_id == "req_1"
  end

  test "from_sse/1 maps each API error type" do
    mapping = %{
      "invalid_request_error" => :bad_request,
      "authentication_error" => :authentication,
      "permission_error" => :permission_denied,
      "not_found_error" => :not_found,
      "billing_error" => :billing,
      "rate_limit_error" => :rate_limit,
      "timeout_error" => :timeout,
      "overloaded_error" => :overloaded,
      "api_error" => :internal_server,
      "something_new_error" => :api_status
    }

    for {api_type, type} <- mapping do
      data = ~s({"type":"error","error":{"type":"#{api_type}","message":"nope"}})

      assert {:error, %Error{type: ^type}} = Event.from_sse(sse("error", data))
    end
  end

  test "from_sse/1 reports data that isn't a JSON object" do
    assert {:error, %Error{type: :stream}} = Event.from_sse(sse("message_stop", "{not json"))
    assert {:error, %Error{type: :stream}} = Event.from_sse(sse("message_stop", "[1,2]"))
  end

  test "from_sse/1 keeps an event type it doesn't model" do
    data = ~s({"type":"future_event","payload":1})

    assert {:ok, %Event.Unknown{type: "future_event", raw: %{"payload" => 1}}} =
             Event.from_sse(sse("future_event", data))
  end
end

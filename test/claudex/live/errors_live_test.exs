defmodule Claudex.Live.ErrorsTest do
  @moduledoc """
  End-to-end coverage of the failure paths — the ones that are hard to
  provoke offline and easy to map to the wrong error type.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Error, Messages, Models}

  test "an unknown model id is a not-found error", %{client: client} do
    assert {:error, %Error{} = error} =
             client
             |> Recorder.record_json("error_404")
             |> Models.retrieve("claude-does-not-exist")

    assert error.type == :not_found
    assert error.status == 404
    assert error.message != ""
  end

  test "an out-of-range max_tokens is a bad-request error", %{client: client} do
    assert {:error, %Error{} = error} =
             client
             |> Recorder.record_json("error_400")
             |> Messages.create(%{
               model: @model,
               max_tokens: 999_999_999,
               messages: [%{role: "user", content: "Hello"}]
             })

    assert error.type == :bad_request
    assert error.status == 400
    assert error.message != ""
  end

  test "count_tokens rejects max_tokens, as its docs claim", %{client: client} do
    assert {:error, %Error{type: :bad_request}} =
             Messages.count_tokens(client, %{
               model: @model,
               max_tokens: 16,
               messages: [%{role: "user", content: "Hello"}]
             })
  end

  test "a bad API key is an authentication error" do
    client = Claudex.new(api_key: "sk-ant-not-a-real-key", max_retries: 0)

    assert {:error, %Error{type: :authentication, status: 401}} =
             Messages.create(client, %{
               model: @model,
               max_tokens: 16,
               messages: [%{role: "user", content: "Hello"}]
             })
  end
end

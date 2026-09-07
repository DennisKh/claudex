defmodule Claudex.Live.MessagesTest do
  @moduledoc """
  End-to-end coverage of `Claudex.Messages.create/2` against the real API.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Message, Messages}

  test "gets a real reply from the Messages API", %{client: client} do
    {:ok, message} =
      client
      |> Recorder.record_json("message")
      |> Messages.create(%{
        model: @model,
        max_tokens: 32,
        messages: [%{role: "user", content: "Reply with exactly one word: pong"}]
      })

    assert message.role == "assistant"
    assert message.id =~ "msg_"
    assert message.model =~ "claude-haiku"
    assert message.stop_reason in ["end_turn", "max_tokens"]
    assert Message.text(message) != ""
    assert message.usage.input_tokens > 0
    assert message.usage.output_tokens > 0
  end

  test "carries context across a multi-turn conversation", %{client: client} do
    first = [Message.user("My favourite colour is chartreuse. Reply with 'noted'.")]

    {:ok, reply} = Messages.create(client, %{model: @model, max_tokens: 32, messages: first})

    follow_up =
      Message.append(first, [
        reply,
        Message.user("What colour did I name? Answer with the colour only.")
      ])

    {:ok, second} =
      Messages.create(client, %{model: @model, max_tokens: 32, messages: follow_up})

    assert second |> Message.text() |> String.downcase() =~ "chartreuse"
  end
end

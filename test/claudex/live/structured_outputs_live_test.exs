defmodule Claudex.Live.StructuredOutputsTest do
  @moduledoc """
  End-to-end coverage of `output_config.format`: that the schema Claudex
  derives from a struct is one the API accepts, and that the reply really is
  JSON in that shape.

  The first test spends no tokens. `count_tokens` validates the schema and
  rejects an unsupported keyword with the same 400 `create/2` would give, which
  makes it the cheap way to catch the API narrowing what it accepts.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Message, Messages}
  alias Claudex.TestSupport.Ticket

  @prompt """
  Open a ticket from this note, and answer only with the ticket:

  "The export button on the reports page has stopped working since Friday.
  Nothing happens when you click it. Reported by Dana Miles, dana@example.com.
  It is blocking the monthly close, so we need it this week."
  """

  test "the schema Claudex derives from a struct is accepted", %{client: client} do
    params = %{
      model: @model,
      messages: [Message.user("hi")],
      output_config: %{format: Ticket}
    }

    assert {:ok, tokens} = Messages.count_tokens(client, params)
    assert tokens > 0
  end

  test "the reply is JSON in the struct's shape", %{client: client} do
    {:ok, message} =
      Messages.create(client, %{
        model: @model,
        max_tokens: 512,
        output_config: %{format: Ticket},
        messages: [Message.user(@prompt)]
      })

    assert message.stop_reason == "end_turn",
           "the reply stopped for #{inspect(message.stop_reason)}, so it isn't the promised shape"

    assert {:ok, ticket} = message |> Message.text() |> JSON.decode()

    assert is_binary(ticket["title"])
    assert ticket["priority"] in ["low", "high"]
    assert is_integer(ticket["id"])
    assert [_first | _rest] = ticket["tags"]
    assert is_binary(ticket["reporter"]["name"])

    # additionalProperties: false on every object, so nothing else comes back.
    assert Map.keys(ticket) -- ~w(id title priority tags due reporter metadata) == []
  end
end

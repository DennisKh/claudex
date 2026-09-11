defmodule Claudex.Live.AttachmentsTest do
  @moduledoc """
  End-to-end coverage of `Claudex.ContentBlock.Document` and
  `Claudex.ContentBlock.Image`: that what the constructors build is what the
  API accepts, and that Claude reads what they carry.

  The first test spends no tokens. `count_tokens` validates a content block the
  same way `create/2` does, so it catches the API narrowing a source type.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Message, Messages}
  alias Claudex.ContentBlock.{Document, Image}

  # One transparent pixel, the smallest thing the vision endpoint accepts.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  defp count(client, block) do
    Messages.count_tokens(client, %{
      model: @model,
      messages: [Message.user([block, %{type: "text", text: "what is this?"}])]
    })
  end

  test "the blocks the constructors build are accepted", %{client: client} do
    assert {:ok, tokens} = count(client, Image.base64(@png, "image/png"))
    assert tokens > 0

    assert {:ok, _} = count(client, Document.text("hello"))

    assert {:ok, _} =
             count(
               client,
               Document.text("hello", title: "Notes", context: "a memo", citations: true)
             )

    assert {:ok, _} =
             count(client, Image.base64(@png, "image/png", cache_control: %{type: "ephemeral"}))
  end

  test "Claude reads a document the block carries", %{client: client} do
    document =
      Document.text("The password for the vault is: rhinoceros.", title: "Vault notes")

    {:ok, message} =
      Messages.create(client, %{
        model: @model,
        max_tokens: 64,
        messages: [
          Message.user([
            document,
            %{type: "text", text: "What is the password? Answer with the word only."}
          ])
        ]
      })

    assert Message.text(message) =~ ~r/rhinoceros/i
  end
end

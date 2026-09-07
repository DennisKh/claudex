defmodule Claudex.Live.BatchesTest do
  @moduledoc """
  End-to-end coverage of the Message Batches API.

  A batch has 24 hours to finish, so this doesn't wait for one: it submits,
  checks the shape of what comes back, proves `results/2` refuses a batch that
  hasn't ended, and cancels. The results-streaming path is covered offline in
  `test/claudex/messages/batches_test.exs`.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Error, Page}
  alias Claudex.Messages.{Batch, Batches}

  defp requests do
    [
      %{
        custom_id: "claudex-live-1",
        params: %{
          model: @model,
          max_tokens: 16,
          messages: [%{role: "user", content: "Reply with exactly one word: pong"}]
        }
      },
      %{
        custom_id: "claudex-live-2",
        params: %{
          model: @model,
          max_tokens: 16,
          messages: [%{role: "user", content: "Reply with exactly one word: ping"}]
        }
      }
    ]
  end

  test "submits a batch, reads it back, and cancels it", %{client: client} do
    assert {:ok, %Batch{} = batch} =
             client |> Recorder.record_json("batch") |> Batches.create(requests())

    assert batch.id =~ "msgbatch_"
    assert batch.type == "message_batch"
    assert batch.processing_status in ["in_progress", "ended"]
    assert batch.request_counts.processing + batch.request_counts.succeeded == 2
    assert %DateTime{} = batch.created_at
    assert %DateTime{} = batch.expires_at

    assert {:ok, %Batch{id: id}} = Batches.retrieve(client, batch.id)
    assert id == batch.id

    unless Batch.ended?(batch) do
      assert {:error, %Error{type: :bad_request, message: message}} =
               Batches.results(client, batch.id)

      assert message =~ "no results yet"
    end

    assert {:ok, %Batch{} = canceled} = Batches.cancel(client, batch.id)
    assert canceled.processing_status in ["canceling", "ended"]
  end

  test "lists batches", %{client: client} do
    assert {:ok, %Page{} = page} = Batches.list(client, limit: 3)

    assert length(page.data) <= 3
    assert Enum.all?(page.data, &match?(%Batch{type: "message_batch"}, &1))
  end
end

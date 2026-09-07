defmodule Claudex.Messages.BatchesTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Message, Page}
  alias Claudex.Messages.{Batch, Batches, BatchResult}

  defmodule Tools do
    use Claudex.Tool

    @doc "Adds two numbers."
    @tool true
    @spec add(number(), number()) :: number()
    def add(a, b), do: a + b
  end

  @batch %{
    "id" => "msgbatch_1",
    "type" => "message_batch",
    "processing_status" => "in_progress",
    "request_counts" => %{
      "processing" => 2,
      "succeeded" => 0,
      "errored" => 0,
      "canceled" => 0,
      "expired" => 0
    },
    "results_url" => nil,
    "created_at" => "2025-01-01T00:00:00Z",
    "expires_at" => "2025-01-02T00:00:00Z",
    "ended_at" => nil,
    "archived_at" => nil,
    "cancel_initiated_at" => nil
  }

  @requests [
    %{
      custom_id: "first",
      params: %{
        model: "claude-haiku-4-5",
        max_tokens: 16,
        messages: [%{role: "user", content: "Hi"}]
      }
    }
  ]

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp ended_batch(results_url) do
    %{
      @batch
      | "processing_status" => "ended",
        "results_url" => results_url,
        "ended_at" => "2025-01-01T00:30:00Z",
        "request_counts" => %{
          "processing" => 0,
          "succeeded" => 1,
          "errored" => 1,
          "canceled" => 1,
          "expired" => 1
        }
    }
  end

  test "create/2 posts the requests and decodes the batch" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/messages/batches"

      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, Jason.decode!(raw_body)})

      Req.Test.json(conn, @batch)
    end)

    assert {:ok, %Batch{} = batch} = Batches.create(client(), @requests)

    assert batch.id == "msgbatch_1"
    assert batch.processing_status == "in_progress"
    refute Batch.ended?(batch)
    assert batch.request_counts.processing == 2
    assert batch.request_counts.succeeded == 0
    assert batch.created_at == ~U[2025-01-01 00:00:00Z]
    assert batch.expires_at == ~U[2025-01-02 00:00:00Z]
    assert batch.ended_at == nil

    assert_received {:body, body}
    assert [%{"custom_id" => "first", "params" => params}] = body["requests"]
    assert params["model"] == "claude-haiku-4-5"
  end

  test "create/2 expands a tools: module inside a request's params" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, Jason.decode!(raw_body)})

      Req.Test.json(conn, @batch)
    end)

    requests = [
      %{custom_id: "first", params: %{model: "claude-haiku-4-5", max_tokens: 16, tools: Tools}}
    ]

    assert {:ok, %Batch{}} = Batches.create(client(), requests)

    assert_received {:body, body}
    assert [%{"params" => %{"tools" => [%{"name" => "add"}]}}] = body["requests"]
  end

  test "retrieve/2 decodes an ended batch" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/messages/batches/msgbatch_1"

      Req.Test.json(
        conn,
        ended_batch("https://api.anthropic.com/v1/messages/batches/msgbatch_1/results")
      )
    end)

    assert {:ok, %Batch{} = batch} = Batches.retrieve(client(), "msgbatch_1")

    assert Batch.ended?(batch)
    assert batch.results_url =~ "/results"
    assert batch.ended_at == ~U[2025-01-01 00:30:00Z]
  end

  test "list/2 decodes a page of batches" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => [@batch],
        "has_more" => false,
        "first_id" => "msgbatch_1",
        "last_id" => "msgbatch_1"
      })
    end)

    assert {:ok, %Page{data: [%Batch{id: "msgbatch_1"}], has_more: false}} =
             Batches.list(client(), limit: 5)
  end

  test "cancel/2 posts to the cancel endpoint" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/messages/batches/msgbatch_1/cancel"

      Req.Test.json(conn, %{@batch | "processing_status" => "canceling"})
    end)

    assert {:ok, %Batch{processing_status: "canceling"}} = Batches.cancel(client(), "msgbatch_1")
  end

  test "delete/2 returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE"

      Req.Test.json(conn, %{"id" => "msgbatch_1", "type" => "message_batch_deleted"})
    end)

    assert :ok = Batches.delete(client(), "msgbatch_1")
  end

  test "results/2 streams every outcome, decoded" do
    results_url = "https://api.anthropic.com/v1/messages/batches/msgbatch_1/results"

    jsonl =
      Enum.map_join(
        [
          %{
            "custom_id" => "first",
            "result" => %{
              "type" => "succeeded",
              "message" => %{
                "id" => "msg_1",
                "role" => "assistant",
                "content" => [%{"type" => "text", "text" => "Hi there"}],
                "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
              }
            }
          },
          %{
            "custom_id" => "second",
            "result" => %{
              "type" => "errored",
              "error" => %{
                "type" => "error",
                "error" => %{"type" => "invalid_request_error", "message" => "bad params"}
              }
            }
          },
          %{"custom_id" => "third", "result" => %{"type" => "canceled"}},
          %{"custom_id" => "fourth", "result" => %{"type" => "expired"}}
        ],
        "",
        &(Jason.encode!(&1) <> "\n")
      )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v1/messages/batches/msgbatch_1" ->
          Req.Test.json(conn, ended_batch(results_url))

        "/v1/messages/batches/msgbatch_1/results" ->
          chunks = for <<chunk::binary-size(9) <- jsonl>>, do: chunk
          rest = binary_part(jsonl, length(chunks) * 9, byte_size(jsonl) - length(chunks) * 9)

          Enum.reduce(chunks ++ [rest], Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, chunk)
            conn
          end)
      end
    end)

    assert {:ok, stream} = Batches.results(client(), "msgbatch_1")

    assert [first, second, third, fourth] = Enum.to_list(stream)

    assert %BatchResult{custom_id: "first", result: {:ok, %Message{} = message}} = first
    assert Message.text(message) == "Hi there"

    assert %BatchResult{custom_id: "second", result: {:error, %Error{} = error}} = second
    assert error.type == :bad_request
    assert error.message == "bad params"

    assert %BatchResult{custom_id: "third", result: :canceled} = third
    assert %BatchResult{custom_id: "fourth", result: :expired} = fourth
  end

  test "results/2 refuses a batch that hasn't finished" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, @batch) end)

    assert {:error, %Error{type: :bad_request, message: message}} =
             Batches.results(client(), "msgbatch_1")

    assert message =~ "no results yet"
    assert message =~ "in_progress"
  end

  test "an empty batch id is rejected without making a request" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("should not have made a request") end)

    assert {:error, %Error{message: "batch id can't be empty"}} = Batches.retrieve(client(), "")
    assert {:error, %Error{type: :bad_request}} = Batches.cancel(client(), "")
    assert {:error, %Error{type: :bad_request}} = Batches.delete(client(), "")
  end
end

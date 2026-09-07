defmodule Claudex.ModelsTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Model, Models, Page}

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp model(id) do
    %{
      "id" => id,
      "type" => "model",
      "display_name" => "Claude Opus 5",
      "created_at" => "2025-02-19T00:00:00Z",
      "max_tokens" => 64_000,
      "max_input_tokens" => 200_000,
      "capabilities" => %{"batch" => %{"supported" => true}}
    }
  end

  test "list/2 decodes a page of models" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"
      assert conn.method == "GET"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-test"]

      Req.Test.json(conn, %{
        "data" => [model("claude-opus-5"), model("claude-haiku-4-5")],
        "has_more" => true,
        "first_id" => "claude-opus-5",
        "last_id" => "claude-haiku-4-5"
      })
    end)

    assert {:ok, %Page{} = page} = Models.list(client())
    assert page.has_more
    assert page.first_id == "claude-opus-5"
    assert page.last_id == "claude-haiku-4-5"
    assert [%Model{id: "claude-opus-5"} = model, %Model{id: "claude-haiku-4-5"}] = page.data
    assert model.display_name == "Claude Opus 5"
    assert model.created_at == ~U[2025-02-19 00:00:00Z]
    assert model.max_tokens == 64_000
    assert model.max_input_tokens == 200_000
    assert model.capabilities == %{"batch" => %{"supported" => true}}
  end

  test "list/2 sends its options as query parameters" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.query_params == %{"limit" => "5", "after_id" => "claude-opus-5"}

      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, %Page{data: []}} = Models.list(client(), limit: 5, after_id: "claude-opus-5")
  end

  test "list/2 sends no query string when given no options" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string == ""

      Req.Test.json(conn, %{"data" => []})
    end)

    # nil, not false: this response carried no has_more at all, and "the endpoint
    # didn't say" is not the same answer as "there are no more pages".
    assert {:ok, %Page{data: [], has_more: nil, first_id: nil, last_id: nil}} =
             Models.list(client())
  end

  test "retrieve/2 decodes one model" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models/claude-opus-5"

      Req.Test.json(conn, model("claude-opus-5"))
    end)

    assert {:ok, %Model{id: "claude-opus-5", type: "model"}} =
             Models.retrieve(client(), "claude-opus-5")
  end

  test "retrieve/2 escapes the model id in the path" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models/weird%2Fid"

      Req.Test.json(conn, model("weird/id"))
    end)

    assert {:ok, %Model{}} = Models.retrieve(client(), "weird/id")
  end

  test "retrieve/2 rejects an empty model id without making a request" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("should not have made a request") end)

    assert {:error, %Error{type: :bad_request, message: "model id can't be empty"}} =
             Models.retrieve(client(), "")
  end

  test "retrieve/2 reports a model that doesn't exist" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "not_found_error", "message" => "model not found"}
      })
    end)

    assert {:error, %Error{type: :not_found, status: 404, message: "model not found"}} =
             Models.retrieve(client(), "claude-nope")
  end

  test "list/2 leaves created_at nil when it isn't a timestamp" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [%{model("claude-opus-5") | "created_at" => "1740009600"}]})
    end)

    assert {:ok, %Page{data: [%Model{created_at: nil}]}} = Models.list(client())
  end
end

defmodule Claudex.MessagesTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Message, Messages}

  defmodule Tools do
    use Claudex.Tool

    @doc "Adds two numbers."
    @tool true
    @spec add(number(), number()) :: number()
    def add(a, b), do: a + b
  end

  defp client(opts \\ []) do
    opts =
      Keyword.merge(
        [api_key: "sk-ant-test", max_retries: 0, req_options: [plug: {Req.Test, __MODULE__}]],
        opts
      )

    Client.new(opts)
  end

  test "create/2 sends the request and decodes a successful reply" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-test"]

      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw_body)

      assert body["model"] == "claude-opus-5"
      assert body["max_tokens"] == 1024
      assert body["stream"] == false

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5",
        "content" => [%{"type" => "text", "text" => "Hi there"}],
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
      })
    end)

    params = %{
      model: "claude-opus-5",
      max_tokens: 1024,
      messages: [%{role: "user", content: "Hello"}]
    }

    assert {:ok, %Message{} = message} = Messages.create(client(), params)
    assert Message.text(message) == "Hi there"
  end

  test "create/2 expands a tools: module into the tool list the API expects" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw_body)

      assert body["tools"] == [
               %{
                 "name" => "add",
                 "description" => "Adds two numbers.",
                 "input_schema" => %{
                   "type" => "object",
                   "properties" => %{"a" => %{"type" => "number"}, "b" => %{"type" => "number"}},
                   "required" => ["a", "b"],
                   "additionalProperties" => false
                 }
               }
             ]

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5",
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end)

    params = %{
      model: "claude-opus-5",
      max_tokens: 1024,
      tools: Tools,
      messages: [%{role: "user", content: "add 1 and 2"}]
    }

    assert {:ok, _message} = Messages.create(client(), params)
  end

  test "create/2 returns a Claudex.Error for a non-2xx response" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "rate_limit_error", "message" => "Rate limited"},
        "request_id" => "req_1"
      })
    end)

    params = %{model: "claude-opus-5", max_tokens: 1024, messages: []}

    assert {:error, %Error{type: :rate_limit, message: "Rate limited", request_id: "req_1"}} =
             Messages.create(client(), params)
  end

  test "create/2 rejects stream: true and points at the streaming functions" do
    params = %{
      model: "claude-opus-5",
      max_tokens: 1024,
      stream: true,
      messages: [%{role: "user", content: "Hello"}]
    }

    assert {:error, %Error{type: :bad_request, message: message}} =
             Messages.create(client(), params)

    assert message =~ "stream!/2 or stream_to/3"
  end

  test "create/2 validates required params without making a request" do
    assert {:error, %Error{type: :bad_request, message: message}} =
             Messages.create(client(), %{model: "claude-opus-5"})

    assert message =~ "messages"
    assert message =~ "max_tokens"
  end

  test "count_tokens/2 returns the input token count" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/messages/count_tokens"

      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw_body)

      assert body["model"] == "claude-opus-5"
      assert body["messages"] == [%{"role" => "user", "content" => "Hello"}]
      refute Map.has_key?(body, "stream")

      Req.Test.json(conn, %{"input_tokens" => 14})
    end)

    params = %{model: "claude-opus-5", messages: [%{role: "user", content: "Hello"}]}

    assert {:ok, 14} = Messages.count_tokens(client(), params)
  end

  test "count_tokens/2 needs only model and messages" do
    assert {:error, %Error{type: :bad_request, message: message}} =
             Messages.count_tokens(client(), %{model: "claude-opus-5"})

    assert message =~ "messages"
    refute message =~ "max_tokens"
  end

  test "count_tokens/2 expands a tools: module like create/2 does" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw_body)

      assert [%{"name" => "add"}] = body["tools"]

      Req.Test.json(conn, %{"input_tokens" => 92})
    end)

    params = %{
      model: "claude-opus-5",
      tools: Tools,
      messages: [%{role: "user", content: "What is 12 plus 30?"}]
    }

    assert {:ok, 92} = Messages.count_tokens(client(), params)
  end

  test "count_tokens/2 reports an API error" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => "max_tokens is not allowed"}
      })
    end)

    params = %{model: "claude-opus-5", messages: [%{role: "user", content: "Hello"}]}

    assert {:error, %Error{type: :bad_request, message: "max_tokens is not allowed"}} =
             Messages.count_tokens(client(), params)
  end
end

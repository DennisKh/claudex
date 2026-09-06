defmodule Claudex.RetryTest do
  @moduledoc """
  Covers when a request is retried and — for streaming — when it deliberately
  isn't.

  Retrying a stream after part of the reply has reached the caller would
  replay that part and bill the request twice, so `Claudex.Stream.Connection`
  disarms retries the moment it forwards a chunk. These tests drive the real
  Req pipeline, since that decision is made by a step inside it.
  """

  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Message, Messages}
  alias Claudex.Stream.Event

  @params %{model: "claude-haiku-4-5", max_tokens: 16, messages: [%{role: "user", content: "Hi"}]}

  @message %{
    "id" => "msg_1",
    "type" => "message",
    "role" => "assistant",
    "model" => "claude-haiku-4-5",
    "content" => [%{"type" => "text", "text" => "Hi there"}],
    "stop_reason" => "end_turn",
    "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
  }

  @sse """
  event: message_start
  data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

  event: message_stop
  data: {"type":"message_stop"}

  """

  defmodule FakeTransport do
    @moduledoc """
    A Req adapter standing in for a connection that drops part-way through a
    200 response — something the plug adapter can't express, since it hands
    the whole body over at once.
    """

    @partial_event ~s(event: message_start\ndata: {"type")

    @doc false
    def run(request) do
      {behaviour, counter} = Req.Request.get_private(request, :fake_transport)
      Agent.update(counter, &(&1 + 1))

      respond(behaviour, request)
    end

    defp respond(:closes_after_streaming, request) do
      {request, _response} = deliver(request, Req.Response.new(status: 200))

      {request, %Req.TransportError{reason: :closed}}
    end

    defp respond(:closes_immediately, request) do
      {request, %Req.TransportError{reason: :closed}}
    end

    defp deliver(request, response) do
      case request.into.({:data, @partial_event}, {request, response}) do
        {:cont, acc} -> acc
        {:halt, acc} -> acc
      end
    end
  end

  defp counter do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  defp attempts(pid), do: Agent.get(pid, & &1)

  defp plug_client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 2,
      req_options: [
        plug: {Req.Test, __MODULE__},
        retry_delay: 0,
        retry_log_level: false
      ]
    )
  end

  defp adapter_client(behaviour, counter) do
    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 2,
        req_options: [adapter: FakeTransport, retry_delay: 0, retry_log_level: false]
      )

    %{client | req: Req.Request.put_private(client.req, :fake_transport, {behaviour, counter})}
  end

  defp send_sse(conn) do
    {:ok, conn} = conn |> Plug.Conn.send_chunked(200) |> Plug.Conn.chunk(@sse)
    conn
  end

  test "a stream is not retried once bytes have reached the caller" do
    pid = counter()

    assert_raise Error, fn ->
      :closes_after_streaming
      |> adapter_client(pid)
      |> Messages.stream!(@params)
      |> Enum.to_list()
    end

    assert attempts(pid) == 1
  end

  test "a stream is retried when it fails before any bytes arrive" do
    pid = counter()

    assert_raise Error, fn ->
      :closes_immediately
      |> adapter_client(pid)
      |> Messages.stream!(@params)
      |> Enum.to_list()
    end

    assert attempts(pid) == 3
  end

  test "a stream recovers from a transient status and yields the retried reply" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    Req.Test.expect(__MODULE__, &send_sse/1)

    events = plug_client() |> Messages.stream!(@params) |> Enum.to_list()

    assert [%Event.MessageStart{}, %Event.MessageStop{}] = events
  end

  test "a stream retried after a retry-after header honours the delay" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "0") |> Plug.Conn.send_resp(529, "")
    end)

    Req.Test.expect(__MODULE__, &send_sse/1)

    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 2,
        req_options: [plug: {Req.Test, __MODULE__}, retry_log_level: false]
      )

    events = client |> Messages.stream!(@params) |> Enum.to_list()

    assert [%Event.MessageStart{}, %Event.MessageStop{}] = events
  end

  test "create/2 retries a rate-limited request and returns the eventual reply" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, @message) end)

    assert {:ok, %Message{} = message} = Messages.create(plug_client(), @params)
    assert Message.text(message) == "Hi there"
  end

  test "create/2 gives up after max_retries and returns the last error" do
    Req.Test.expect(__MODULE__, 3, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"type" => "error", "error" => %{"message" => "rate limited"}})
    end)

    assert {:error, %Error{type: :rate_limit, status: 429, message: "rate limited"}} =
             Messages.create(plug_client(), @params)
  end

  test "create/2 does not retry a 400" do
    pid = counter()

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(pid, &(&1 + 1))
      Plug.Conn.send_resp(conn, 400, "")
    end)

    assert {:error, %Error{type: :bad_request}} = Messages.create(plug_client(), @params)
    assert attempts(pid) == 1
  end
end

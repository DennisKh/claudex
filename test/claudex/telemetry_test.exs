defmodule Claudex.TelemetryTest do
  use ExUnit.Case, async: false

  alias Claudex.{Client, Message, Messages, Telemetry, ToolRunner}
  alias Claudex.TestSupport.MessageStream

  defmodule Calculator do
    use Claudex.Tool

    @doc "Adds two integers."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b), do: a + b

    @doc "Refuses on purpose."
    @tool true
    @spec refuse() :: String.t()
    def refuse, do: raise(Claudex.Tool.Error, "not today")
  end

  @params %{
    model: "claude-haiku-4-5",
    max_tokens: 64,
    tools: Calculator,
    messages: [%{role: "user", content: "hi"}]
  }

  defmodule Forwarder do
    @moduledoc false

    @doc false
    def handle(event, measurements, metadata, %{pid: pid}) do
      send(pid, {:telemetry, event, measurements, metadata})
    end
  end

  setup context do
    handler = "test-#{inspect(context.test)}"

    # A captured module function rather than an anonymous one: telemetry warns
    # about the latter, and it's right to.
    :telemetry.attach_many(handler, Telemetry.events(), &Forwarder.handle/4, %{pid: self()})

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok
  end

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp message(content, stop_reason \\ "end_turn") do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => content,
      "stop_reason" => stop_reason,
      "usage" => %{"input_tokens" => 11, "output_tokens" => 7}
    }
  end

  defp respond_with(replies) do
    reply_with(replies, &Req.Test.json/2)
  end

  # The runner streams every request, so its replies go back as SSE.
  defp stream_with(replies) do
    reply_with(replies, &MessageStream.respond/2)
  end

  defp reply_with(replies, respond) do
    {:ok, counter} = Agent.start_link(fn -> replies end)

    Req.Test.stub(__MODULE__, fn conn ->
      reply = Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)

      conn
      |> Plug.Conn.put_resp_header("request-id", "req_test_1")
      |> respond.(reply)
    end)
  end

  test "a request span carries status, request id, and token counts" do
    respond_with([message([%{"type" => "text", "text" => "hello"}])])

    assert {:ok, _message} = Messages.create(client(), @params)

    assert_receive {:telemetry, [:claudex, :request, :start], measurements, metadata}
    assert is_integer(measurements.system_time)
    assert metadata.method == :post
    assert metadata.path == "/v1/messages"

    assert_receive {:telemetry, [:claudex, :request, :stop], measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.status == 200
    assert metadata.request_id == "req_test_1"
    assert metadata.model == "claude-haiku-4-5"
    assert metadata.input_tokens == 11
    assert metadata.output_tokens == 7
  end

  test "a cached request reports what the cache did" do
    cached =
      message([%{"type" => "text", "text" => "hello"}])
      |> put_in(["usage"], %{
        "input_tokens" => 11,
        "output_tokens" => 7,
        "cache_creation_input_tokens" => 4096,
        "cache_read_input_tokens" => 0
      })

    respond_with([cached])

    assert {:ok, _message} = Messages.create(client(), @params)

    assert_receive {:telemetry, [:claudex, :request, :stop], _measurements, metadata}
    assert metadata.cache_creation_input_tokens == 4096
    assert metadata.cache_read_input_tokens == 0
  end

  test "a request without caching reports no cache counters" do
    respond_with([message([%{"type" => "text", "text" => "hello"}])])

    assert {:ok, _message} = Messages.create(client(), @params)

    assert_receive {:telemetry, [:claudex, :request, :stop], _measurements, metadata}
    refute Map.has_key?(metadata, :cache_creation_input_tokens)
    refute Map.has_key?(metadata, :cache_read_input_tokens)
  end

  test "request metadata never carries the conversation or the client" do
    respond_with([message([%{"type" => "text", "text" => "a secret answer"}])])

    assert {:ok, _message} = Messages.create(client(), @params)

    assert_receive {:telemetry, [:claudex, :request, :stop], _measurements, metadata}

    encoded = inspect(metadata)
    refute encoded =~ "secret"
    refute encoded =~ "sk-ant"

    assert Map.keys(metadata) |> Enum.sort() ==
             [
               :input_tokens,
               :method,
               :model,
               :output_tokens,
               :path,
               :request_id,
               :status
             ]
  end

  test "a tool span reports the outcome of each call" do
    stream_with([
      message(
        [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "add",
            "input" => %{"a" => 1, "b" => 2}
          }
        ],
        "tool_use"
      ),
      message([%{"type" => "text", "text" => "3"}])
    ])

    assert {:ok, _turn} = ToolRunner.run(client(), @params)

    assert_receive {:telemetry, [:claudex, :tool, :stop], measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.tool == "add"
    assert metadata.outcome == :ok
  end

  test "a refused tool is reported apart from a working one" do
    stream_with([
      message(
        [%{"type" => "tool_use", "id" => "toolu_1", "name" => "refuse", "input" => %{}}],
        "tool_use"
      ),
      message([%{"type" => "text", "text" => "understood"}])
    ])

    assert {:ok, _turn} = ToolRunner.run(client(), @params)

    assert_receive {:telemetry, [:claudex, :tool, :stop], _measurements, %{outcome: :refused}}
  end

  test "the runner reports each turn and why the loop ended" do
    stream_with([
      message(
        [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "add",
            "input" => %{"a" => 1, "b" => 2}
          }
        ],
        "tool_use"
      ),
      message([%{"type" => "text", "text" => "3"}])
    ])

    assert {:ok, _turn} = ToolRunner.run(client(), @params)

    assert_receive {:telemetry, [:claudex, :tool_runner, :turn], %{tool_calls: 1}, %{index: 1}}
    assert_receive {:telemetry, [:claudex, :tool_runner, :turn], %{tool_calls: 0}, %{index: 2}}
    assert_receive {:telemetry, [:claudex, :tool_runner, :stop], %{turns: 2}, %{stop: :completed}}
  end

  test "hitting the turn limit is reported as such" do
    tool_call =
      message(
        [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "add",
            "input" => %{"a" => 1, "b" => 2}
          }
        ],
        "tool_use"
      )

    stream_with(List.duplicate(tool_call, 2))

    assert {:ok, _turn} = ToolRunner.run(client(), @params, max_turns: 2)

    assert_receive {:telemetry, [:claudex, :tool_runner, :stop], %{turns: 2}, %{stop: :max_turns}}
  end

  test "attach_default_logger/1 is idempotent and detaches cleanly" do
    assert Telemetry.attach_default_logger() == :ok
    assert Telemetry.attach_default_logger() == :ok
    assert Telemetry.detach_default_logger() == :ok
    assert Telemetry.detach_default_logger() == :ok
  end

  test "the default logger writes a line per event at the level asked for" do
    respond_with([message([%{"type" => "text", "text" => "hello"}])])
    Telemetry.attach_default_logger(level: :info)
    on_exit(&Telemetry.detach_default_logger/0)

    logged =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _message} =
                 Messages.create(client(), Map.put(@params, :messages, [Message.user("hi")]))
      end)

    assert logged =~ "claudex POST /v1/messages claude-haiku-4-5 → 200"
    assert logged =~ "request_id=req_test_1"
    assert logged =~ "(11 in / 7 out)"
  end

  test "a streaming request reports the same span as a non-streaming one" do
    sse = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, conn} =
        conn
        |> Plug.Conn.put_resp_header("request-id", "req_test_stream")
        |> Plug.Conn.send_chunked(200)
        |> Plug.Conn.chunk(sse)

      conn
    end)

    client() |> Messages.stream!(@params) |> Enum.to_list()

    assert_receive {:telemetry, [:claudex, :request, :start], _measurements, start_metadata}
    assert start_metadata.model == "claude-haiku-4-5"
    assert start_metadata.path == "/v1/messages"

    assert_receive {:telemetry, [:claudex, :request, :stop], measurements, metadata}
    assert metadata.status == 200
    assert metadata.request_id == "req_test_stream"
    assert metadata.model == "claude-haiku-4-5"
    assert measurements.chunks > 0
    assert measurements.bytes > 0
  end

  test "a streaming span carries no prompt, completion or key" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, conn} =
        conn
        |> Plug.Conn.send_chunked(200)
        |> Plug.Conn.chunk("event: message_stop\ndata: {}\n\n")

      conn
    end)

    client() |> Messages.stream!(@params) |> Enum.to_list()

    assert_receive {:telemetry, [:claudex, :request, :stop], _measurements, metadata}

    assert Map.keys(metadata) |> Enum.sort() ==
             [:method, :model, :path, :request_id, :status]
  end

  test "a request without a model in its body reports none" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [], "has_more" => false})
    end)

    assert {:ok, _page} = Claudex.Models.list(client())

    assert_receive {:telemetry, [:claudex, :request, :stop], _measurements, metadata}
    refute Map.has_key?(metadata, :model)
  end

  defmodule FailingAdapter do
    @moduledoc false

    @doc false
    def run(%{method: :never_matches}), do: :unreachable
  end

  test "the exception path carries no prompt, no key, and no stacktrace" do
    client =
      Client.new(
        api_key: "sk-ant-SECRETKEY",
        max_retries: 0,
        req_options: [adapter: FailingAdapter]
      )

    params = %{
      model: "claude-haiku-4-5",
      max_tokens: 8,
      messages: [Message.user("MY-SECRET-PROMPT")]
    }

    assert catch_error(Messages.create(client, params))

    assert_receive {:telemetry, [:claudex, :request, :exception], measurements, metadata}
    assert is_integer(measurements.duration)

    # :telemetry.span/3 would put :reason and :stacktrace here, and a stack
    # frame from inside a Req step holds the whole request — key and body.
    assert Map.keys(metadata) |> Enum.sort() == [:error, :kind, :method, :model, :path]
    assert metadata.kind == :error
    assert metadata.error == FunctionClauseError

    encoded = inspect(metadata, limit: :infinity, printable_limit: :infinity)
    refute encoded =~ "SECRETKEY"
    refute encoded =~ "MY-SECRET-PROMPT"
  end
end

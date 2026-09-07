defmodule Claudex.Stream.ForwarderTest do
  @moduledoc """
  `Claudex.Messages.stream_to/3` is the public way in; this covers the process
  behind it directly.
  """

  use ExUnit.Case, async: true

  alias Claudex.Client
  alias Claudex.Stream.{Event, Forwarder, Handle}

  @params %{model: "claude-haiku-4-5", max_tokens: 16, messages: [%{role: "user", content: "Hi"}]}

  defmodule StubTransport do
    @moduledoc """
    A Req adapter serving one canned stream. A plug stub resolves through
    `$callers`, which a process started elsewhere doesn't inherit.
    """

    @sse """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @doc false
    def run(request) do
      case request.into.({:data, @sse}, {request, Req.Response.new(status: 200)}) do
        {:cont, acc} -> acc
        {:halt, acc} -> acc
      end
    end
  end

  defp client do
    Client.new(api_key: "sk-ant-test", max_retries: 0, req_options: [adapter: StubTransport])
  end

  test "start/3 forwards to the process and ref it was given" do
    ref = make_ref()

    assert {:ok, %Handle{ref: ^ref, pid: pid}} =
             Forwarder.start(client(), @params, to: self(), ref: ref)

    assert is_pid(pid)

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 2_000
    assert_receive {:claudex, ^ref, {:event, %Event.MessageStop{}}}, 2_000
    assert_receive {:claudex, ^ref, :done}, 2_000
  end

  test "start/3 mints a ref and defaults to the calling process" do
    assert {:ok, %Handle{ref: ref}} = Forwarder.start(client(), @params, [])

    assert_receive {:claudex, ^ref, :done}, 2_000
  end

  test "there is no child_spec: a stream cannot be restarted" do
    refute function_exported?(Forwarder, :child_spec, 1)
    refute function_exported?(Forwarder, :start_link, 1)
  end
end

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

  defmodule StallingTransport do
    @moduledoc """
    Delivers one complete event, then stalls the way the API does while the
    model is thinking. A cancel that waits for the next chunk cannot land
    before the stall ends.
    """

    @first_event """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

    """

    @stall :timer.seconds(5)

    @doc false
    def run(request) do
      {_action, acc} =
        request.into.({:data, @first_event}, {request, Req.Response.new(status: 200)})

      Process.sleep(@stall)

      acc
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

  test "cancel/1 stops a stream stalled mid-think, without waiting for the next event" do
    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 0,
        req_options: [adapter: StallingTransport]
      )

    {:ok, %Handle{ref: ref} = handle} = Forwarder.start(client, @params, [])

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 1_000

    Claudex.Stream.cancel(handle)

    # The transport is five seconds into a stall. Anything that only notices a
    # cancel when the next chunk arrives cannot report inside this window.
    assert_receive {:claudex, ^ref, :cancelled}, 500

    refute_receive {:claudex, ^ref, :done}, 100
  end
end

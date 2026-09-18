defmodule Claudex.Stream.ForwarderTest do
  @moduledoc """
  `Claudex.Messages.stream_to/3` is the public way in; this covers the process
  behind it directly.
  """

  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Messages}
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

  defmodule ResumingTransport do
    @moduledoc """
    Stalls after the first event, then finishes. Lets a test watch one stream
    run to completion while another is cancelled during the same stall.
    """

    @first_event """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

    """

    @rest """
    event: message_stop
    data: {"type":"message_stop"}

    """

    @stall 400

    @doc false
    def run(request) do
      {_action, acc} =
        request.into.({:data, @first_event}, {request, Req.Response.new(status: 200)})

      Process.sleep(@stall)

      case request.into.({:data, @rest}, acc) do
        {:cont, acc} -> acc
        {:halt, acc} -> acc
      end
    end
  end

  defp client do
    Client.new(api_key: "sk-ant-test", max_retries: 0, req_options: [adapter: StubTransport])
  end

  test "events/3 forwards to the process and ref it was given" do
    ref = make_ref()

    assert {:ok, %Handle{ref: ^ref, pid: pid}} =
             Forwarder.events(client(), @params, to: self(), ref: ref)

    assert is_pid(pid)

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 2_000
    assert_receive {:claudex, ^ref, {:event, %Event.MessageStop{}}}, 2_000
    assert_receive {:claudex, ^ref, :done}, 2_000
  end

  test "events/3 mints a ref and defaults to the calling process" do
    assert {:ok, %Handle{ref: ref_one}} = Forwarder.events(client(), @params, [])
    assert {:ok, %Handle{ref: ref_two}} = Forwarder.events(client(), @params, [])

    assert ref_one != ref_two

    assert_receive {:claudex, ^ref_one, :done}, 2_000
    assert_receive {:claudex, ^ref_two, :done}, 2_000
  end

  test "a throw from inside the stream reaches the caller as an error, not a hang" do
    assert {:ok, %Handle{ref: ref}} = Forwarder.start([], fn _sink -> throw(:boom) end)

    assert_receive {:claudex, ^ref, {:error, %Error{type: :stream}}}, 2_000
  end

  test "a destination name nobody holds is reported once, not once per message" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, %Handle{pid: pid}} =
          Forwarder.events(client(), @params, to: :claudex_no_such_destination)

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      end)

    assert log =~ "no process registered as :claudex_no_such_destination"

    # Two events and a :done went undelivered. Reporting each would drown a
    # real reply in hundreds of identical lines.
    assert log |> String.split("no process registered as") |> length() == 2
  end

  test "a destination name nobody holds does not take the caller down" do
    parent = self()

    ExUnit.CaptureLog.capture_log(fn ->
      caller =
        spawn(fn ->
          {:ok, _handle} = Forwarder.events(client(), @params, to: :claudex_no_such_destination)
          Process.sleep(300)
          send(parent, :survived)
        end)

      monitor = Process.monitor(caller)

      # send/2 to an unregistered name is an ArgumentError, and reporting that
      # error to the same name raises again. Escaping the forwarder kills the
      # caller it is linked to.
      assert_receive :survived, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    end)
  end

  test "Messages.stream_to/3 passes monitor: true through, and it stops the stream" do
    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 0,
        req_options: [adapter: StallingTransport]
      )

    dead = spawn(fn -> :ok end)
    gone = Process.monitor(dead)
    assert_receive {:DOWN, ^gone, :process, ^dead, _reason}, 1_000

    {:ok, %Handle{pid: pid}} = Messages.stream_to(client, @params, to: dead, monitor: true)

    finished = Process.monitor(pid)

    # The transport is five seconds into a stall. Without the watch reaching
    # the forwarder, this process sits there for all of it.
    assert_receive {:DOWN, ^finished, :process, ^pid, reason}, 1_000
    assert reason in [:normal, :noproc]
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

    {:ok, %Handle{ref: ref} = handle} = Forwarder.events(client, @params, [])

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 1_000

    Claudex.Stream.cancel(handle)

    # The transport is five seconds into a stall. Anything that only notices a
    # cancel when the next chunk arrives cannot report inside this window.
    assert_receive {:claudex, ^ref, :cancelled}, 500

    refute_receive {:claudex, ^ref, :done}, 100
  end

  test "cancelling one stream leaves another alone" do
    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 0,
        req_options: [adapter: ResumingTransport]
      )

    {:ok, %Handle{ref: cancelled_ref} = cancelled} = Forwarder.events(client, @params, [])
    {:ok, %Handle{ref: kept_ref}} = Forwarder.events(client, @params, [])

    assert_receive {:claudex, ^cancelled_ref, {:event, %Event.MessageStart{}}}, 1_000
    assert_receive {:claudex, ^kept_ref, {:event, %Event.MessageStart{}}}, 1_000

    Claudex.Stream.cancel(cancelled)

    assert_receive {:claudex, ^cancelled_ref, :cancelled}, 500
    assert_receive {:claudex, ^kept_ref, :done}, 2_000

    refute_receive {:claudex, ^kept_ref, :cancelled}, 100
    refute_receive {:claudex, ^cancelled_ref, :done}, 100
  end

  test "a cancel carrying another stream's ref is ignored" do
    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 0,
        req_options: [adapter: ResumingTransport]
      )

    {:ok, %Handle{ref: ref, pid: pid}} = Forwarder.events(client, @params, [])

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 1_000

    # Same mailbox, different stream: only the pinned ref may halt this one.
    send(pid, {:claudex_cancel, make_ref()})

    # The rest of the reply still arrives. An unpinned match would halt the
    # transport here and the stream would end without ever sending this.
    assert_receive {:claudex, ^ref, {:event, %Event.MessageStop{}}}, 2_000
    assert_receive {:claudex, ^ref, :done}, 1_000
    refute_receive {:claudex, ^ref, :cancelled}, 100
  end
end

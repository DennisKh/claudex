defmodule Claudex.ChunkStreamTest do
  use ExUnit.Case, async: true

  alias Claudex.{ChunkStream, Client}

  defmodule FloodTransport do
    @moduledoc """
    Offers a hundred chunks as fast as the stream will take them, counting each
    one it hands over, the way a fast download outruns a slow consumer. Req
    refuses options it doesn't know, so the counter is found by the request's
    path.
    """

    @doc false
    def run(request) do
      counter = :persistent_term.get({__MODULE__, request.url.path})

      Enum.reduce_while(1..100, {request, Req.Response.new(status: 200)}, fn n, acc ->
        :counters.add(counter, 1, 1)
        request.into.({:data, "chunk #{n}\n"}, acc)
      end)
    end
  end

  defmodule Chunks do
    @moduledoc false
    @behaviour Claudex.ChunkStream.Decoder

    @impl true
    def new, do: nil

    @impl true
    def decode(state, chunk), do: {[chunk], state}

    @impl true
    def flush(state), do: {[], state}
  end

  defmodule OverloadedTransport do
    @moduledoc """
    Answers every attempt with a 529 that asks for a short wait, so the request
    process spends its time asleep between retries. The adapter runs in that
    process, so it names itself to the test, the last of its `$callers`.
    """

    @doc false
    def run(request) do
      send(List.last(Process.get(:"$callers")), {:attempt, self()})

      {request, Req.Response.new(status: 529, headers: [{"retry-after-ms", "100"}], body: "")}
    end
  end

  defmodule SilentTransport do
    @moduledoc "Never answers, the way a slow first byte holds a request."

    @doc false
    def run(request) do
      send(List.last(Process.get(:"$callers")), {:attempt, self()})
      Process.sleep(:infinity)

      {request, Req.Response.new(status: 200)}
    end
  end

  defmodule OneChunkTransport do
    @moduledoc "Hands over one chunk, then waits for the consumer to ask for more."

    @doc false
    def run(request) do
      send(List.last(Process.get(:"$callers")), {:attempt, self()})
      request.into.({:data, "first\n"}, {request, Req.Response.new(status: 200)})
    end
  end

  # Each runs the request process into a different wait: asleep between
  # retries, blocked on a response, and parked for demand mid-body.
  for {phase, transport} <- [
        {"between retries", OverloadedTransport},
        {"while the response hasn't started", SilentTransport},
        {"while it waits for demand mid-body", OneChunkTransport}
      ] do
    test "a consumer that dies #{phase} takes the request process with it" do
      client =
        Client.new(
          api_key: "sk-ant-test",
          max_retries: 5,
          req_options: [adapter: unquote(transport)]
        )

      test = self()

      consumer =
        spawn(fn ->
          Process.put(:"$callers", [test])

          client
          |> ChunkStream.stream([method: :get, url: "/v1/models"], {Chunks, &[&1]})
          |> Stream.each(fn _chunk -> Process.sleep(:infinity) end)
          |> Stream.run()
        end)

      assert_receive {:attempt, producer}, 1_000
      gone = Process.monitor(producer)
      Process.exit(consumer, :kill)

      assert_receive {:DOWN, ^gone, :process, ^producer, _reason}, 500
      refute_receive {:attempt, _producer}, 300
    end
  end

  describe "watch/2" do
    defp blocked, do: spawn(fn -> Process.sleep(:infinity) end)

    defp ends?(pid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    end

    # A worker that starts a watcher on `watched`, names it to the test, then
    # waits to be told how to end.
    defp worker(watched, on_down) do
      test = self()

      spawn(fn ->
        send(test, {:watcher, ChunkStream.watch(watched, on_down)})

        receive do
          :return -> :ok
          :crash -> exit(:boom)
        end
      end)
    end

    test "runs on_down when the watched process dies, whatever the worker is doing" do
      test = self()
      watched = blocked()
      worker(watched, fn -> send(test, :on_down) end)
      assert_receive {:watcher, watcher}

      Process.exit(watched, :kill)

      assert_receive :on_down, 500
      ends?(watcher)
    end

    test "ends with the worker, however the worker ends" do
      for ending <- [:return, :crash, :killed] do
        watched = blocked()
        worker = worker(watched, fn -> :ok end)
        assert_receive {:watcher, watcher}

        case ending do
          :killed -> Process.exit(worker, :kill)
          signal -> send(worker, signal)
        end

        ends?(watcher)
        assert Process.alive?(watched)
      end
    end

    test "takes the worker down if it is killed itself" do
      worker = worker(blocked(), fn -> :ok end)
      assert_receive {:watcher, watcher}

      Process.exit(watcher, :kill)

      ends?(worker)
    end

    test "counts a name with no process registered as down" do
      test = self()

      worker(:claudex_nobody_registered, fn -> send(test, :on_down) end)

      assert_receive :on_down, 500
    end
  end

  test "a consumer that stalls holds the request back to one chunk ahead of it" do
    counter = :counters.new(1, [])
    path = "/results/#{System.unique_integer([:positive])}"
    :persistent_term.put({FloodTransport, path}, counter)
    on_exit(fn -> :persistent_term.erase({FloodTransport, path}) end)

    client =
      Client.new(api_key: "sk-ant-test", max_retries: 0, req_options: [adapter: FloodTransport])

    [stalled_at] =
      client
      |> ChunkStream.stream([method: :get, url: path], {Chunks, &[&1]})
      |> Stream.map(fn _chunk ->
        Process.sleep(200)
        {:messages, mailbox} = Process.info(self(), :messages)
        {:counters.get(counter, 1), length(mailbox)}
      end)
      |> Enum.take(1)

    assert stalled_at == {2, 1}
  end
end

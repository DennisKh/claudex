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
    Answers every attempt with a 529 that asks for a short wait, telling the
    test each time. The test is the last of the request's `$callers`.
    """

    @doc false
    def run(request) do
      send(List.last(Process.get(:"$callers")), :attempt)

      {request, Req.Response.new(status: 529, headers: [{"retry-after-ms", "100"}], body: "")}
    end
  end

  test "a consumer that dies stops the request between retries" do
    client =
      Client.new(
        api_key: "sk-ant-test",
        max_retries: 5,
        req_options: [adapter: OverloadedTransport]
      )

    test = self()

    consumer =
      spawn(fn ->
        Process.put(:"$callers", [test])

        client
        |> ChunkStream.stream([method: :get, url: "/v1/models"], {Chunks, &[&1]})
        |> Enum.to_list()
      end)

    assert_receive :attempt, 1_000
    Process.exit(consumer, :kill)

    refute_receive :attempt, 500
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

defmodule Claudex.StreamTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Message, Messages, Stream}
  alias Claudex.ContentBlock
  alias Claudex.Stream.{Event, Handle}

  @params %{
    model: "claude-opus-5",
    max_tokens: 1024,
    messages: [%{role: "user", content: "Hello"}]
  }

  defp client(opts \\ []) do
    [api_key: "sk-ant-test", max_retries: 0, req_options: [plug: {Req.Test, __MODULE__}]]
    |> Keyword.merge(opts)
    |> Client.new()
  end

  defp event(name, payload), do: "event: #{name}\ndata: #{Jason.encode!(payload)}\n\n"

  defp text_stream do
    [
      event("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "role" => "assistant",
          "model" => "claude-opus-5",
          "content" => [],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
        }
      }),
      event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      event("ping", %{"type" => "ping"}),
      event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      }),
      event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => ", world"}
      }),
      event("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 15}
      }),
      event("message_stop", %{"type" => "message_stop"})
    ]
  end

  defp stub_chunks(chunks, on_request \\ fn conn -> conn end) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = on_request.(conn)

      Enum.reduce(chunks, Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)
  end

  test "stream!/2 yields typed events and sets stream: true on the request" do
    parent = self()

    stub_chunks(text_stream(), fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, Jason.decode!(raw_body)})
      conn
    end)

    events = client() |> Messages.stream!(@params) |> Enum.to_list()

    assert_received {:body, body}
    assert body["stream"] == true

    assert [
             %Event.MessageStart{},
             %Event.ContentBlockStart{index: 0},
             %Event.ContentBlockDelta{delta: {:text, "Hello"}},
             %Event.ContentBlockDelta{delta: {:text, ", world"}},
             %Event.ContentBlockStop{index: 0},
             %Event.MessageDelta{stop_reason: "end_turn"},
             %Event.MessageStop{}
           ] = events
  end

  test "stream!/2 delivers events split across chunk boundaries" do
    text_stream() |> Enum.join() |> chunk_every(9) |> stub_chunks()

    assert {:ok, "Hello, world"} = client() |> Messages.stream!(@params) |> Stream.text()
  end

  test "final_message/1 assembles the same message a non-streaming call returns" do
    stub_chunks(text_stream())

    assert {:ok, %Message{} = message} =
             client() |> Messages.stream!(@params) |> Stream.final_message()

    assert message.id == "msg_1"
    assert message.stop_reason == "end_turn"
    assert message.usage.input_tokens == 10
    assert message.usage.output_tokens == 15
    assert [%ContentBlock.Text{text: "Hello, world"}] = message.content
  end

  test "stream!/2 raises the error the API sends part-way through" do
    stub_chunks([
      Enum.at(text_stream(), 0),
      event("error", %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      })
    ])

    assert_raise Error, "Overloaded", fn ->
      client() |> Messages.stream!(@params) |> Enum.to_list()
    end
  end

  test "final_message/1 returns a mid-stream error instead of raising" do
    stub_chunks([
      Enum.at(text_stream(), 0),
      event("error", %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      })
    ])

    assert {:error, %Error{type: :overloaded}} =
             client() |> Messages.stream!(@params) |> Stream.final_message()
  end

  test "stream!/2 reports a non-2xx response with the API's error body" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        Jason.encode!(%{
          "type" => "error",
          "error" => %{"type" => "invalid_request_error", "message" => "max_tokens is too large"},
          "request_id" => "req_1"
        })
      )
    end)

    assert {:error, %Error{} = error} =
             client() |> Messages.stream!(@params) |> Stream.final_message()

    assert error.type == :bad_request
    assert error.status == 400
    assert error.message == "max_tokens is too large"
    assert error.request_id == "req_1"
  end

  test "final_message/1 reports a stream that ends without a message" do
    stub_chunks([event("ping", %{"type" => "ping"})])

    assert {:error, %Error{type: :stream}} =
             client() |> Messages.stream!(@params) |> Stream.final_message()
  end

  test "stream!/2 stops the request when the consumer stops enumerating" do
    stub_chunks(text_stream())

    assert [%Event.MessageStart{}, %Event.ContentBlockStart{}] =
             client() |> Messages.stream!(@params) |> Enum.take(2)
  end

  test "stream!/2 raises on a missing required parameter" do
    assert_raise Error, ~r/missing required params: max_tokens/, fn ->
      Messages.stream!(client(), Map.delete(@params, :max_tokens))
    end
  end

  test "stream_to/3 sends events, then :done" do
    stub_chunks(text_stream())

    assert {:ok, %Handle{ref: ref}} = Messages.stream_to(client(), @params)

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStart{}}}, 2_000

    assert_receive {:claudex, ^ref, {:event, %Event.ContentBlockDelta{delta: {:text, "Hello"}}}},
                   2_000

    assert_receive {:claudex, ^ref, {:event, %Event.MessageStop{}}}, 2_000
    assert_receive {:claudex, ^ref, :done}, 2_000
  end

  test "stream_to/3 sends the error instead of raising" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

    assert {:ok, %Handle{ref: ref}} = Messages.stream_to(client(), @params)

    assert_receive {:claudex, ^ref, {:error, %Error{type: :rate_limit}}}, 2_000
    refute_receive {:claudex, ^ref, :done}
  end

  test "stream_to/3 delivers to another process when told to" do
    stub_chunks(text_stream())
    parent = self()
    target = spawn_link(fn -> forward_all(parent) end)

    assert {:ok, %Handle{ref: ref}} = Messages.stream_to(client(), @params, to: target)

    assert_receive {:forwarded, {:claudex, ^ref, {:event, %Event.MessageStart{}}}}, 2_000
    assert_receive {:forwarded, {:claudex, ^ref, :done}}, 2_000
  end

  test "stream_to/3 returns an error for a missing required parameter" do
    assert {:error, %Error{type: :bad_request}} =
             Messages.stream_to(client(), Map.delete(@params, :max_tokens))
  end

  test "cancel/1 stops a stream before its next event" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:request_started, self()})

      receive do
        :proceed -> :ok
      end

      Enum.reduce(text_stream(), Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)

    assert {:ok, handle} = Messages.stream_to(client(), @params)
    assert_receive {:request_started, request}, 2_000

    assert Stream.cancel(handle) == :ok
    send(request, :proceed)

    ref = handle.ref
    assert_receive {:claudex, ^ref, :cancelled}, 2_000
    refute_received {:claudex, ^ref, :done}
    refute_received {:claudex, ^ref, {:event, _event}}
  end

  defp forward_all(parent) do
    receive do
      message ->
        send(parent, {:forwarded, message})
        forward_all(parent)
    end
  end

  defp chunk_every(binary, size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end
end

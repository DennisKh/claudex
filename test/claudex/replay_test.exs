defmodule Claudex.ReplayTest do
  use ExUnit.Case, async: true

  alias Claudex.{
    Client,
    Error,
    FileMetadata,
    Files,
    Message,
    Messages,
    Model,
    Models,
    Page,
    Stream
  }

  alias Claudex.ContentBlock
  alias Claudex.Messages.{Batch, Batches}
  alias Claudex.Stream.{Accumulator, Event, SSE}
  alias Claudex.TestSupport.Fixtures

  @params %{
    model: "claude-haiku-4-5",
    max_tokens: 64,
    messages: [%{role: "user", content: "Hello"}]
  }

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp stub_json(fixture, status \\ 200) do
    body = Fixtures.json!(fixture)

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp stub_sse(fixture, chunk_size) do
    chunks = fixture |> Fixtures.sse!() |> Fixtures.chunks(chunk_size)

    Req.Test.stub(__MODULE__, fn conn ->
      Enum.reduce(chunks, Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)
  end

  defp events_from(fixture) do
    {sse_events, decoder} = SSE.decode(SSE.new(), Fixtures.sse!(fixture))
    {trailing, _decoder} = SSE.flush(decoder)

    (sse_events ++ trailing)
    |> Enum.flat_map(fn sse_event ->
      case Event.from_sse(sse_event) do
        {:ok, event} -> [event]
        :ignore -> []
        {:error, error} -> flunk("fixture #{fixture} produced an error: #{inspect(error)}")
      end
    end)
  end

  test "a recorded message decodes end to end" do
    stub_json("message")

    assert {:ok, %Message{} = message} = Messages.create(client(), @params)

    assert message.id =~ "msg_"
    assert message.type == "message"
    assert message.role == "assistant"
    assert message.model =~ "claude-haiku-4-5"
    assert message.stop_reason == "end_turn"
    assert Message.text(message) != ""
    assert message.usage.input_tokens > 0
    assert message.usage.output_tokens > 0
    assert [%ContentBlock.Text{}] = message.content
  end

  test "a recorded stream replays into the same message, however it is chunked" do
    for chunk_size <- [1, 7, 64, 4096] do
      stub_sse("message_stream", chunk_size)

      events = client() |> Messages.stream!(@params) |> Enum.to_list()

      assert %Event.MessageStart{} = hd(events)
      assert %Event.MessageStop{} = List.last(events)

      assert {:ok, message} = Stream.final_message(events)
      assert Message.text(message) != ""
      assert message.stop_reason == "end_turn"
      assert message.usage.output_tokens > 0
    end
  end

  test "a recorded stream carries the ping the API really sends" do
    raw = Fixtures.sse!("message_stream")

    assert raw =~ "event: ping"

    {sse_events, _decoder} = SSE.decode(SSE.new(), raw)

    assert Enum.any?(sse_events, &(&1.name == "ping"))
    refute Enum.any?(events_from("message_stream"), &match?(%Event.Unknown{}, &1))
  end

  test "a recorded tool call decodes into a ToolUse block with parsed input" do
    stub_json("tool_use")

    assert {:ok, message} = Messages.create(client(), @params)
    assert message.stop_reason == "tool_use"

    [tool_use] = Message.tool_uses(message)

    assert tool_use.id =~ "toolu_"
    assert tool_use.name == "get_temperature"
    assert is_map(tool_use.input) and tool_use.input != %{}
  end

  test "a recorded thinking response decodes into a Thinking block" do
    stub_json("thinking")

    assert {:ok, message} = Messages.create(client(), @params)

    thinking = Enum.find(message.content, &match?(%ContentBlock.Thinking{}, &1))

    assert thinking.thinking != ""
    assert thinking.signature != ""
  end

  test "a recorded thinking stream rebuilds the block from its deltas" do
    events = events_from("thinking_stream")

    assert Enum.any?(events, &match?(%Event.ContentBlockDelta{delta: {:thinking, _chunk}}, &1))
    assert Enum.any?(events, &match?(%Event.ContentBlockDelta{delta: {:signature, _sig}}, &1))

    message =
      events
      |> Enum.reduce(Accumulator.new(), &Accumulator.add(&2, &1))
      |> Accumulator.message()

    thinking = Enum.find(message.content, &match?(%ContentBlock.Thinking{}, &1))

    assert thinking.thinking != ""
    assert thinking.signature != ""
  end

  test "a recorded cached response carries the cache token counts" do
    stub_json("cached")

    assert {:ok, message} = Messages.create(client(), @params)

    cache_tokens =
      (message.usage.cache_creation_input_tokens || 0) +
        (message.usage.cache_read_input_tokens || 0)

    assert cache_tokens > 0
  end

  test "recorded error bodies map to the right error type" do
    stub_json("error_404", 404)

    assert {:error, %Error{type: :not_found, status: 404} = not_found} =
             Models.retrieve(client(), "claude-does-not-exist")

    assert not_found.message != ""

    stub_json("error_400", 400)

    assert {:error, %Error{type: :bad_request, status: 400} = bad_request} =
             Messages.create(client(), @params)

    assert bad_request.message != ""
  end

  test "a recorded models page decodes into models" do
    stub_json("models_page")

    assert {:ok, %Page{data: [%Model{} = model | _rest]} = page} = Models.list(client())

    assert is_boolean(page.has_more)
    assert page.first_id == model.id
    assert model.type == "model"
    assert %DateTime{} = model.created_at
    assert model.max_input_tokens > 0
  end

  test "a recorded model decodes with its capabilities" do
    stub_json("model")

    assert {:ok, %Model{} = model} = Models.retrieve(client(), "claude-haiku-4-5")

    assert model.id =~ "claude-haiku-4-5"
    assert model.display_name != ""
    assert model.capabilities["thinking"]["supported"] == true
  end

  test "a recorded file decodes with the GA shape" do
    stub_json("file")

    assert {:ok, %FileMetadata{} = file} = Files.retrieve(client(), "file_1")

    assert file.id =~ "file_"
    assert file.type == "file"
    assert file.mime_type == "text/plain"
    assert file.size_bytes > 0
    assert %DateTime{} = file.created_at
    assert file.downloadable == false

    # expires_at exists only on the GA response; the beta shape omits it.
    assert %DateTime{} = file.expires_at
  end

  test "a recorded files page uses a cursor rather than ids" do
    stub_json("files_page")

    assert {:ok, %Page{data: [%FileMetadata{} | _rest]} = page} = Files.list(client())

    assert page.first_id == nil
    assert page.last_id == nil
  end

  test "a recorded batch decodes with its request counts" do
    stub_json("batch")

    assert {:ok, %Batch{} = batch} = Batches.retrieve(client(), "msgbatch_1")

    assert batch.id =~ "msgbatch_"
    assert batch.type == "message_batch"
    assert batch.processing_status == "in_progress"
    refute Batch.ended?(batch)
    assert batch.results_url == nil
    assert batch.request_counts.processing == 2
    assert %DateTime{} = batch.created_at
    assert %DateTime{} = batch.expires_at
    assert batch.ended_at == nil
  end
end

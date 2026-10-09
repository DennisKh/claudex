defmodule Claudex.Live.ServerToolsTest do
  @moduledoc """
  End-to-end coverage of a server-side tool: the blocks `web_search` sends
  back, a search run through `Claudex.ToolRunner`, and how `:every` batches
  around one.

  A request can't ask the API to pause a turn, so resuming a `pause_turn` is
  covered offline in `Claudex.ToolRunnerTest`.

  `web_search` is billed per search, and Claude Haiku 4.5 rejects the tool
  outright, hence a model of this test's own rather than the shared `@model`.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Message, Messages, ToolRunner}
  alias Claudex.ContentBlock.{ServerToolResult, ServerToolUse}
  alias Claudex.Stream.Event.{ContentBlockStart, ContentBlockStop}

  @model "claude-sonnet-5"

  # Dated on purpose: the tool type carries its version, and a model that
  # doesn't take this one says so in the 400. `allowed_callers` pins the direct
  # form: from `web_search_20260209` on, the default runs the search from inside
  # code execution, which puts the result blocks a turn deeper.
  @web_search %{
    type: "web_search_20260209",
    name: "web_search",
    max_uses: 8,
    allowed_callers: ["direct"]
  }

  test "a search run through ToolRunner.stream/3 keeps its query and completes",
       %{client: client} do
    turns =
      client
      |> ToolRunner.stream(
        %{
          model: @model,
          max_tokens: 1024,
          tools: [%{@web_search | max_uses: 1}],
          messages: [
            Message.user(
              "Search the web once for the population of Kyiv, then answer in one sentence."
            )
          ]
        },
        max_turns: 6
      )
      |> Enum.to_list()

    last = List.last(turns)

    assert last.stop == :completed,
           "expected the loop to finish, got #{inspect(last.stop)} after #{length(turns)} turn(s)"

    assert Message.text(last.message) =~ ~r/Kyiv/i

    # The loop runs on the streaming path, where a server tool's arguments
    # arrive as fragments. A search replayed with an empty input is a search
    # the API starts over.
    searches =
      for turn <- turns,
          %ServerToolUse{} = call <- turn.message.content,
          do: call

    assert searches != [], "the prompt produced no web search to check"

    for call <- searches do
      assert call.input != %{}, "a search went back into the history with no query"
      assert ContentBlock.to_param(call)["input"] == call.input
    end
  end

  test "web search comes back as server tool blocks", %{client: client} do
    {:ok, message} =
      client
      |> Recorder.record_json("server_tools")
      |> Messages.create(%{
        model: @model,
        max_tokens: 2048,
        tools: [@web_search],
        messages: [Message.user("Search the web: what is the population of Kyiv?")]
      })

    call = find(message, ServerToolUse)
    result = find(message, ServerToolResult)

    assert call.name == "web_search"
    assert result.tool == :web_search
    assert result.tool_use_id == call.id
    assert message.usage.server_tool_use["web_search_requests"] >= 1

    refute result.error_code, "the search failed: #{result.error_code}"

    assert Enum.all?(
             result.content,
             &match?(%{"type" => "web_search_result", "url" => _, "encrypted_content" => _}, &1)
           )

    # Replaying has to hand back what the API sent: a changed or missing
    # encrypted_content is a 400 on the next turn.
    assert ContentBlock.to_param(result) == result.raw
  end

  defp find(message, struct) do
    block = Enum.find(message.content, &(is_struct(&1) and &1.__struct__ == struct))

    assert block, "no #{inspect(struct)} block in #{inspect(Enum.map(message.content, & &1))}"

    block
  end

  test "stream_to/3 with :every delivers what came before a search while the search runs",
       %{client: client} do
    {:ok, handle} =
      Messages.stream_to(
        client,
        %{
          model: @model,
          max_tokens: 1024,
          tools: [%{@web_search | max_uses: 1}],
          messages: [Message.user("Search the web once for the year Kyiv's metro opened.")]
        },
        every: 50
      )

    batches = collect_timed(handle.ref, [])
    arrivals = Enum.map(batches, fn {at, _events} -> at end)
    silences = Enum.zip_with(arrivals, tl(arrivals), &(&2 - &1))

    search =
      first_index(batches, &match?(%ContentBlockStart{content_block: %ServerToolUse{}}, &1))

    assert search, "the prompt produced no web search to time"

    asked =
      Enum.find_index(
        batches,
        &holds?(&1, fn e -> match?(%ContentBlockStop{index: ^search}, e) end)
      )

    # Nothing streams while the search runs, so that is the longest silence.
    # A batch released only by the next event would end the silence instead
    # of starting it, arriving together with the result.
    assert Enum.at(silences, asked) == Enum.max(silences),
           "the call's end came after the longest silence: #{inspect(silences)}"

    assert holds?(
             Enum.at(batches, asked + 1),
             &match?(%ContentBlockStart{content_block: %ServerToolResult{}}, &1)
           )
  end

  defp collect_timed(ref, batches) do
    receive do
      {:claudex, ^ref, {:events, events}} ->
        collect_timed(ref, [{System.monotonic_time(:millisecond), events} | batches])

      {:claudex, ^ref, :done} ->
        Enum.reverse(batches)

      {:claudex, ^ref, {:error, error}} ->
        flunk("the stream failed: #{Exception.message(error)}")
    after
      30_000 -> flunk("the stream never finished")
    end
  end

  defp first_index(batches, fun) do
    batches
    |> Enum.flat_map(fn {_at, events} -> events end)
    |> Enum.find_value(fn event -> if fun.(event), do: event.index end)
  end

  defp holds?({_at, events}, fun), do: Enum.any?(events, fun)
end

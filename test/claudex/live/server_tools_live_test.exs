defmodule Claudex.Live.ServerToolsTest do
  @moduledoc """
  End-to-end coverage of a server-side tool loop: the blocks `web_search`
  sends back, and what `Claudex.ToolRunner` does when the API pauses a turn
  part-way through one.

  A pause is not something a request can ask for. It happens when the
  server-side loop runs long enough to hit its own iteration limit, so the
  prompt here is written to keep it searching, and the assertion holds either
  way: if a pause arrives, the loop must have carried on past it.

  `web_search` is billed per search, and Claude Haiku 4.5 rejects the tool
  outright, hence a model of this test's own rather than the shared `@model`.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Message, Messages, ToolRunner}
  alias Claudex.ContentBlock.{ServerToolResult, ServerToolUse}

  @moduletag timeout: 180_000

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

  @prompt """
  Search the web for each of these separately, then answer in one paragraph:
  the current population of Kyiv, the year its metro opened, and the name of
  its longest bridge. Search again to confirm anything you are unsure of.
  """

  test "a paused turn never ends the conversation", %{client: client} do
    turns =
      client
      |> ToolRunner.stream(
        %{
          model: @model,
          max_tokens: 4096,
          tools: [@web_search],
          messages: [Message.user(@prompt)]
        },
        max_turns: 6
      )
      |> Enum.to_list()

    last = List.last(turns)

    assert last.stop == :completed,
           "expected the loop to finish, got #{inspect(last.stop)} after #{length(turns)} turn(s)"

    assert Message.text(last.message) =~ ~r/Kyiv/i

    paused = Enum.filter(turns, &(&1.message.stop_reason == "pause_turn"))

    for turn <- paused do
      assert turn.index < last.index,
             "turn #{turn.index} paused and the loop stopped there"
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
end

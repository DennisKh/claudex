defmodule Claudex.Live.SkillsTest do
  @moduledoc """
  End-to-end coverage of Agent Skills in a Messages request, with Anthropic's
  `xlsx` skill run through `Claudex.ToolRunner`.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Files, Message, ToolRunner}
  alias Claudex.ToolRunner.Turn

  @moduletag timeout: 300_000

  @skills [%{type: "anthropic", skill_id: "xlsx", version: "latest"}]
  @code_execution %{type: "code_execution_20250825", name: "code_execution"}

  defmodule Checkpoint do
    @moduledoc false
    use Claudex.Tool

    @doc "Confirms the step is done and says what to do next."
    @tool true
    @spec checkpoint() :: String.t()
    def checkpoint, do: "Done. Go on to the spreadsheet."
  end

  test "a skill's spreadsheet comes back as a file id that downloads", %{client: client} do
    prompt =
      "Use the xlsx skill to create budget.xlsx with the rows Rent 1000, Food 300 " <>
        "and a SUM total row. Keep it minimal."

    turns =
      client
      |> Recorder.record_stream("skill_stream")
      |> ToolRunner.stream!(params([@code_execution], prompt))
      |> Enum.to_list()

    assert %Turn{stop: :completed} = last = List.last(turns)
    assert %{"skills" => [%{"skill_id" => "xlsx", "version" => version}]} = last.message.container
    refute version == "latest"

    assert [file_id | _rest] = file_ids = file_ids(turns)
    on_exit(fn -> Enum.each(file_ids, &Files.delete(client, &1)) end)

    assert {:ok, %{downloadable: true}} = Files.retrieve(client, file_id)
    # An xlsx file is a zip archive.
    assert {:ok, "PK" <> _rest} = Files.download(client, file_id)
  end

  test "every turn of a run keeps the skills in the container it carries", %{client: client} do
    prompt =
      "Do these steps in order. 1. With code execution, run `ls /skills`. " <>
        "2. Only after that, call the checkpoint tool. 3. Then use the xlsx skill " <>
        "to create one.xlsx holding the number 1 in A1."

    turns =
      client
      |> ToolRunner.stream!(params([Checkpoint, @code_execution], prompt))
      |> Enum.to_list()

    on_exit(fn -> Enum.each(file_ids(turns), &Files.delete(client, &1)) end)

    assert [%Turn{tool_uses: [%{name: "checkpoint"}]} | _rest] = turns
    assert %Turn{stop: :completed} = List.last(turns)

    # A container named by its id alone runs without the skills, so a turn that
    # kept the id but dropped the map would come back with no `skills`.
    containers = for %{message: %{container: %{"id" => _id} = container}} <- turns, do: container

    assert [first, _second | _rest] = containers
    assert Enum.all?(containers, &(&1["id"] == first["id"]))
    assert Enum.all?(containers, &match?(%{"skills" => [%{"skill_id" => "xlsx"}]}, &1))
  end

  defp params(tools, prompt) do
    %{
      model: @model,
      max_tokens: 4096,
      container: %{skills: @skills},
      tools: tools,
      messages: [Message.user(prompt)]
    }
  end

  defp file_ids(turns), do: Enum.flat_map(turns, &Message.file_ids(&1.message))
end

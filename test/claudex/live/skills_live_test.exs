defmodule Claudex.Live.SkillsTest do
  @moduledoc """
  End-to-end coverage of Agent Skills in a Messages request, with Anthropic's
  `xlsx` skill run through `Claudex.ToolRunner`.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Files, Message, Skills, ToolRunner}
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

  defmodule Publisher do
    @moduledoc false
    use Claudex.Tool

    # Tools run outside the test process, so the client and skill come from a
    # persistent term the test sets.
    @doc "Publishes the next version of the word-pin skill."
    @tool true
    @spec publish() :: String.t()
    def publish do
      {client, skill_id} = :persistent_term.get(__MODULE__)

      {:ok, _version} =
        Skills.create_version(client, skill_id, [
          {skill_md(), "SKILL.md"},
          {"b\n", "word-beta.txt"}
        ])

      "Published."
    end

    @doc false
    def skill_md do
      """
      ---
      name: word-pin
      description: Lists its own folder. Use when asked to list the word-pin skill.
      ---

      probe
      """
    end
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

  test "a version published mid-run doesn't reach the run's later turns", %{client: client} do
    {:ok, skill} =
      Skills.create(client, [{Publisher.skill_md(), "SKILL.md"}, {"a\n", "word-alpha.txt"}])

    on_exit(fn -> Skills.delete(client, skill.id) end)
    :persistent_term.put(Publisher, {client, skill.id})
    on_exit(fn -> :persistent_term.erase(Publisher) end)

    prompt =
      "Do these steps in order. 1. With code execution, run `ls /skills/word-pin`. " <>
        "2. Only after that, call the publish tool. 3. After it answers, run " <>
        "`ls /skills/word-pin` again with code execution."

    params = %{
      model: @model,
      max_tokens: 1024,
      container: %{skills: [%{type: "custom", skill_id: skill.id, version: "latest"}]},
      tools: [Publisher, @code_execution],
      messages: [Message.user(prompt)]
    }

    turns = client |> ToolRunner.stream!(params) |> Enum.to_list()

    assert %Turn{stop: :completed} = List.last(turns)
    assert {:ok, %{latest_version_id: latest}} = Skills.retrieve(client, skill.id)
    refute latest == skill.latest_version_id

    published_in =
      Enum.find_index(turns, fn turn -> Enum.any?(turn.tool_uses, &(&1.name == "publish")) end)

    # Only the listings from the replies after the publish ran can show v2.
    listings =
      for %Turn{message: message} <- Enum.drop(turns, published_in + 1),
          %ContentBlock.ServerToolResult{tool: :bash_code_execution, content: content} <-
            message.content,
          do: content["stdout"]

    assert [_listing | _rest] = listings
    assert Enum.all?(listings, &(&1 =~ "word-alpha.txt"))
    refute Enum.any?(listings, &(&1 =~ "word-beta.txt"))
  end

  test "a halted run resumes from turn.container in its container, on its versions", %{
    client: client
  } do
    {:ok, skill} =
      Skills.create(client, [{Publisher.skill_md(), "SKILL.md"}, {"a\n", "word-alpha.txt"}])

    on_exit(fn -> Skills.delete(client, skill.id) end)

    prompt =
      "Do these steps in order. 1. With code execution, run `ls /skills/word-pin`. " <>
        "2. Only after that, call the checkpoint tool. 3. After it answers, run " <>
        "`ls /skills/word-pin` again with code execution."

    params = %{
      model: @model,
      max_tokens: 1024,
      container: %{skills: [%{type: "custom", skill_id: skill.id, version: "latest"}]},
      tools: [Checkpoint, @code_execution],
      messages: [Message.user(prompt)]
    }

    {:ok, halted} =
      ToolRunner.run(client, params, before_call: fn _call -> {:halt, :awaiting_approval} end)

    assert %Turn{stop: :awaiting_approval, container: %{"id" => container_id}} = halted

    {:ok, _version} =
      Skills.create_version(client, skill.id, [
        {Publisher.skill_md(), "SKILL.md"},
        {"b\n", "word-beta.txt"}
      ])

    resumed =
      client
      |> ToolRunner.stream!(%{params | messages: halted.messages, container: halted.container},
        tool_results: halted.tool_results
      )
      |> Enum.to_list()

    assert %Turn{stop: :completed} = List.last(resumed)
    assert Enum.all?(resumed, &(&1.container["id"] == container_id))

    listings =
      for %Turn{message: message} <- resumed,
          %ContentBlock.ServerToolResult{tool: :bash_code_execution, content: content} <-
            message.content,
          do: content["stdout"]

    assert [_listing | _rest] = listings
    assert Enum.all?(listings, &(&1 =~ "word-alpha.txt"))
  end

  defp file_ids(turns), do: Enum.flat_map(turns, &Message.file_ids(&1.message))
end

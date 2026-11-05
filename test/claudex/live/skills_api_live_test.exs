defmodule Claudex.Live.SkillsAPITest do
  @moduledoc """
  End-to-end coverage of the Skills API. Creating, listing and deleting a
  skill is free; only the request that runs one costs tokens.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Error, Messages, Page, Skill, Skills}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  defp skill_md(name) do
    """
    ---
    name: #{name}
    description: Reads the secret word from docs/word.txt. Use when asked for the secret word.
    ---

    # Secret word

    The secret word is in docs/word.txt, next to this file.
    """
  end

  defp delete_on_exit(client, skill_id) do
    on_exit(fn -> Skills.delete(client, skill_id) end)
  end

  test "creates a skill from a directory, which a request then runs", %{
    client: client,
    tmp_dir: tmp_dir
  } do
    dir = Path.join(tmp_dir, "pineapple-word")
    File.mkdir_p!(Path.join(dir, "docs"))
    File.mkdir_p!(Path.join(dir, "assets"))
    File.write!(Path.join(dir, "SKILL.md"), skill_md("pineapple-word"))
    File.write!(Path.join(dir, "docs/word.txt"), "mango\n")
    File.cp!(Recorder.path("red_square.png"), Path.join(dir, "assets/red.png"))
    File.write!(Path.join(dir, ".hidden"), "not uploaded\n")

    assert {:ok, %Skill{} = skill} =
             client |> Recorder.record_json("skill") |> Skills.create(dir)

    delete_on_exit(client, skill.id)

    assert skill.id =~ "skill_"
    assert skill.type == "skill"
    assert skill.source == "custom"
    assert skill.display_name == "pineapple-word"
    assert skill.latest_version_id =~ "skver_"
    assert %DateTime{} = skill.created_at

    assert {:ok, %Skill{id: id}} = Skills.retrieve(client, skill.id)
    assert id == skill.id

    png_size = File.stat!(Recorder.path("red_square.png")).size

    {:ok, message} =
      Messages.create(client, %{
        model: @model,
        max_tokens: 1024,
        container: %{skills: [%{type: "custom", skill_id: skill.id, version: "latest"}]},
        tools: [%{type: "code_execution_20250825", name: "code_execution"}],
        messages: [
          %{
            role: "user",
            content:
              "Run exactly this one bash command and nothing else: " <>
                "ls -A /skills/pineapple-word; cat /skills/pineapple-word/docs/word.txt; " <>
                "wc -c < /skills/pineapple-word/assets/red.png"
          }
        ]
      })

    assert [stdout | _rest] =
             for(
               %ContentBlock.ServerToolResult{tool: :bash_code_execution, content: content} <-
                 message.content,
               do: content["stdout"]
             )

    assert stdout =~ "mango"
    assert stdout =~ "SKILL.md"
    assert stdout =~ to_string(png_size)
    refute stdout =~ ".hidden"
  end

  test "creates a skill from content with a display name, lists it, and deletes it", %{
    client: client
  } do
    assert {:ok, %Skill{} = skill} =
             Skills.create(
               client,
               [{skill_md("pineapple-pairs"), "SKILL.md"}, {"mango\n", "docs/word.txt"}],
               display_name: "Pineapple pairs"
             )

    delete_on_exit(client, skill.id)

    assert skill.display_name == "Pineapple pairs"

    assert {:ok, %Page{} = page} =
             client |> Recorder.record_json("skills_page") |> Skills.list(source: "custom")

    assert Enum.any?(page.data, &(&1.id == skill.id))
    assert Enum.all?(page.data, &(&1.source == "custom"))
    assert page.has_more == nil

    assert client |> Skills.stream!(source: "custom", limit: 1) |> Enum.any?(&(&1.id == skill.id))

    assert :ok = Skills.delete(client, skill.id)
    assert {:error, %Error{type: :not_found}} = Skills.retrieve(client, skill.id)
  end

  test "lists Anthropic's skills, which can't be deleted", %{client: client} do
    assert {:ok, page} = Skills.list(client, source: "anthropic")

    assert %Skill{source: "anthropic"} = Enum.find(page.data, &(&1.id == "xlsx"))
    assert {:error, %Error{type: :bad_request}} = Skills.delete(client, "xlsx")
  end

  test "refuses a skill without a SKILL.md", %{client: client} do
    assert {:error, %Error{type: :bad_request} = error} =
             Skills.create(client, [{"notes\n", "docs/notes.txt"}])

    assert error.message =~ "SKILL.md"
  end
end

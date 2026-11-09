defmodule Claudex.Live.SkillsAPITest do
  @moduledoc """
  End-to-end coverage of the Skills API. Creating, listing and deleting a
  skill is free; only the request that runs one costs tokens.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{ContentBlock, Error, Messages, Page, Skill, Skills}
  alias Claudex.Skill.Version

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

  test "creates a skill from a zip of its folder", %{client: client, tmp_dir: tmp_dir} do
    zip = Path.join(tmp_dir, "pineapple-zip.zip")

    {:ok, _zip} =
      :zip.create(String.to_charlist(zip), [
        {~c"pineapple-zip/SKILL.md", skill_md("pineapple-zip")},
        {~c"pineapple-zip/docs/word.txt", "mango\n"}
      ])

    assert {:ok, %Skill{} = skill} = Skills.create(client, zip, display_name: nil)

    delete_on_exit(client, skill.id)

    assert skill.display_name == "pineapple-zip"
  end

  test "refuses a skill without a SKILL.md", %{client: client} do
    assert {:error, %Error{type: :bad_request} = error} =
             Skills.create(client, [{"notes\n", "docs/notes.txt"}])

    assert error.message =~ "SKILL.md"
  end

  describe "versions" do
    test "a new version becomes the latest, pages, and can be deleted down to one", %{
      client: client
    } do
      {:ok, skill} =
        Skills.create(client, [
          {skill_md("pineapple-versions"), "SKILL.md"},
          {"mango\n", "docs/word.txt"}
        ])

      delete_on_exit(client, skill.id)

      assert {:ok, %Version{} = version} =
               client
               |> Recorder.record_json("skill_version")
               |> Skills.create_version(skill.id, [{skill_md("pineapple-versions"), "SKILL.md"}])

      assert version.id =~ "skver_"
      assert version.type == "skill_version"
      assert version.skill_id == skill.id
      assert version.name == "pineapple-versions"
      assert version.description =~ "secret word"
      assert %DateTime{} = version.created_at

      assert {:ok, %Skill{latest_version_id: latest}} = Skills.retrieve(client, skill.id)
      assert latest == version.id
      assert {:ok, %Version{id: ^latest}} = Skills.retrieve_version(client, skill.id, "latest")

      assert {:ok, %Version{id: first}} =
               Skills.retrieve_version(client, skill.id, skill.latest_version_id)

      assert {:ok, %Page{data: versions}} =
               client
               |> Recorder.record_json("skill_versions_page")
               |> Skills.list_versions(skill.id)

      assert Enum.map(versions, & &1.id) == [latest, first]

      assert client |> Skills.stream_versions!(skill.id, limit: 1) |> Enum.map(& &1.id) ==
               [latest, first]

      assert :ok = Skills.delete_version(client, skill.id, latest)
      assert {:ok, %Skill{latest_version_id: ^first}} = Skills.retrieve(client, skill.id)

      assert {:error, %Error{type: :bad_request}} =
               Skills.delete_version(client, skill.id, first)
    end

    test "a request runs the version it pins, without the files a later one left out", %{
      client: client
    } do
      {:ok, skill} =
        Skills.create(client, [
          {skill_md("pineapple-pinned"), "SKILL.md"},
          {"mango\n", "docs/word.txt"}
        ])

      delete_on_exit(client, skill.id)

      {:ok, _version} =
        Skills.create_version(client, skill.id, [{skill_md("pineapple-pinned"), "SKILL.md"}])

      command = "ls -A /skills/pineapple-pinned"

      assert bash_stdout(client, skill.id, skill.latest_version_id, command) =~ "docs"

      # SKILL.md shows the latest is mounted, so a missing docs/ isn't a failed command.
      latest = bash_stdout(client, skill.id, "latest", command)
      assert latest =~ "SKILL.md"
      refute latest =~ "docs"
    end

    test "refuses a version whose SKILL.md renames the skill", %{client: client} do
      {:ok, skill} = Skills.create(client, [{skill_md("pineapple-named"), "SKILL.md"}])

      delete_on_exit(client, skill.id)

      assert {:error, %Error{type: :bad_request} = error} =
               Skills.create_version(client, skill.id, [
                 {skill_md("pineapple-renamed"), "SKILL.md"}
               ])

      assert error.message =~ "pineapple-named"
    end

    test "looks up an Anthropic skill's latest version", %{client: client} do
      assert {:ok, %Version{skill_id: "xlsx", id: "skver_" <> _id}} =
               Skills.retrieve_version(client, "xlsx", "latest")
    end
  end

  defp bash_stdout(client, skill_id, version, command) do
    {:ok, message} =
      Messages.create(client, %{
        model: @model,
        max_tokens: 1024,
        container: %{skills: [%{type: "custom", skill_id: skill_id, version: version}]},
        tools: [%{type: "code_execution_20250825", name: "code_execution"}],
        messages: [
          %{
            role: "user",
            content: "Run exactly this one bash command and nothing else: " <> command
          }
        ]
      })

    [stdout | _rest] =
      for %ContentBlock.ServerToolResult{tool: :bash_code_execution, content: content} <-
            message.content,
          do: content["stdout"]

    stdout
  end
end

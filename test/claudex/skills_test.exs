defmodule Claudex.SkillsTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Page, Skill, Skills}
  alias Claudex.TestSupport.Fixtures

  @moduletag :tmp_dir

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp stub_capture(body) do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn, request_body})
      Req.Test.json(conn, body)
    end)
  end

  defp file_parts(body) do
    ~r/name="files\[\]"; filename="([^"]+)"\r\n(?:content-type: [^\r]+\r\n)?\r\n(.*?)\r\n--/s
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [filename, content] -> {filename, content} end)
  end

  describe "create/3" do
    test "uploads a directory's files under its name, skipping dotfiles", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "expense-report")
      File.mkdir_p!(Path.join(dir, "scripts"))
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join(dir, "SKILL.md"), "skill")
      File.write!(Path.join(dir, "scripts/build.py"), "print(1)")
      File.write!(Path.join(dir, ".env"), "SECRET=1")
      File.write!(Path.join(dir, ".git/config"), "[core]")

      stub_capture(Fixtures.json!("skill"))

      assert {:ok, %Skill{}} = Skills.create(client(), dir)

      assert_received {:request, conn, body}
      assert conn.method == "POST"
      assert conn.request_path == "/v1/skills"

      assert file_parts(body) == [
               {"expense-report/SKILL.md", "skill"},
               {"expense-report/scripts/build.py", "print(1)"}
             ]

      refute body =~ "display_name"
    end

    test "takes a directory path with a trailing slash", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "expense-report")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "skill")

      stub_capture(Fixtures.json!("skill"))

      assert {:ok, %Skill{}} = Skills.create(client(), dir <> "/")

      assert_received {:request, _conn, body}
      assert file_parts(body) == [{"expense-report/SKILL.md", "skill"}]
    end

    test "skips symlinks, to files or folders, inside or outside the skill", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "expense-report")
      File.mkdir_p!(Path.join(dir, "scripts"))
      File.write!(Path.join(dir, "SKILL.md"), "skill")
      File.write!(Path.join(dir, "scripts/build.py"), "print(1)")
      File.write!(Path.join(dir, ".env"), "SECRET=1")
      File.write!(Path.join(tmp_dir, "outside.txt"), "outside")

      File.ln_s!(".env", Path.join(dir, "env"))
      File.ln_s!("scripts", Path.join(dir, "linked-scripts"))
      File.ln_s!("../../outside.txt", Path.join(dir, "scripts/outside"))
      File.ln_s!(tmp_dir, Path.join(dir, "parent"))

      stub_capture(Fixtures.json!("skill"))

      assert {:ok, %Skill{}} = Skills.create(client(), dir)

      assert_received {:request, _conn, body}

      assert file_parts(body) == [
               {"expense-report/SKILL.md", "skill"},
               {"expense-report/scripts/build.py", "print(1)"}
             ]
    end

    test "takes a directory whose path holds glob characters", %{tmp_dir: tmp_dir} do
      dir = Path.join([tmp_dir, "skills[1]", "{a,b}"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "skill")

      stub_capture(Fixtures.json!("skill"))

      assert {:ok, %Skill{}} = Skills.create(client(), dir)

      assert_received {:request, _conn, body}
      assert file_parts(body) == [{"{a,b}/SKILL.md", "skill"}]
    end

    test "uploads content pairs at the paths given, with a display name" do
      stub_capture(Fixtures.json!("skill"))

      assert {:ok, %Skill{}} =
               Skills.create(client(), [{"skill", "SKILL.md"}, {"x", "docs/notes.txt"}],
                 display_name: "Expense report"
               )

      assert_received {:request, _conn, body}
      assert file_parts(body) == [{"SKILL.md", "skill"}, {"docs/notes.txt", "x"}]
      assert body =~ ~s(name="display_name"\r\n\r\nExpense report)
    end

    test "decodes the skill the API created" do
      stub_capture(Fixtures.json!("skill"))

      assert {:ok, skill} = Skills.create(client(), [{"skill", "SKILL.md"}])

      assert skill.id == "skill_01N2DPTyA5rX6fXvakHms93e"
      assert skill.type == "skill"
      assert skill.display_name == "pineapple-word"
      assert skill.latest_version_id == "skver_01J7SxMdkLgGJq2PZpHRG8Fv"
      assert skill.source == "custom"
      assert skill.created_at == ~U[2026-11-05 13:13:24.423254Z]
      assert skill.updated_at == ~U[2026-11-05 13:13:24.423254Z]
    end

    test "raises for a directory that doesn't exist or isn't one", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "SKILL.md")
      File.write!(file, "skill")

      assert_raise File.Error, ~r/no such file or directory/, fn ->
        Skills.create(client(), Path.join(tmp_dir, "missing"))
      end

      assert_raise File.Error, ~r/not a directory/, fn -> Skills.create(client(), file) end
    end
  end

  describe "list/2 and stream!/2" do
    test "list/2 sends the paging options and decodes the page" do
      stub_capture(Fixtures.json!("skills_page"))

      assert {:ok, %Page{data: [%Skill{display_name: "Pineapple pairs"}], next_page: nil}} =
               Skills.list(client(), limit: 5, page: "page_abc", source: "custom")

      assert_received {:request, conn, _body}
      assert conn.request_path == "/v1/skills"
      assert conn.query_string == "limit=5&page=page_abc&source=custom"
    end

    test "stream!/2 follows next_page until it runs out" do
      %{"data" => [skill]} = Fixtures.json!("skills_page")
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:page, conn.query_params["page"]})

        case conn.query_params["page"] do
          nil ->
            Req.Test.json(conn, %{"data" => [skill], "next_page" => "page_2"})

          "page_2" ->
            Req.Test.json(conn, %{"data" => [%{skill | "id" => "skill_2"}], "next_page" => nil})
        end
      end)

      ids = client() |> Skills.stream!() |> Enum.map(& &1.id)

      assert ids == [skill["id"], "skill_2"]
      assert_received {:page, nil}
      assert_received {:page, "page_2"}
    end
  end

  describe "retrieve/2 and delete/2" do
    test "retrieve/2 escapes the id into the path" do
      stub_capture(Fixtures.json!("skill"))

      assert {:ok, %Skill{}} = Skills.retrieve(client(), "skill_1/../x")

      assert_received {:request, conn, _body}
      assert conn.method == "GET"
      assert conn.request_path == "/v1/skills/skill_1%2F..%2Fx"
    end

    test "delete/2 answers :ok" do
      stub_capture(%{"id" => "skill_1", "type" => "skill_deleted"})

      assert :ok = Skills.delete(client(), "skill_1")

      assert_received {:request, conn, _body}
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/skills/skill_1"
    end

    test "an empty id is refused without a request" do
      for id <- [nil, ""] do
        assert {:error, %Error{type: :bad_request}} = Skills.retrieve(client(), id)
        assert {:error, %Error{type: :bad_request}} = Skills.delete(client(), id)
      end

      refute_received {:request, _conn, _body}
    end
  end
end

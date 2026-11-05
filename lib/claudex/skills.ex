defmodule Claudex.Skills do
  @moduledoc """
  The Skills API: upload a custom skill once, then name it in as many Messages
  requests as you like.

      {:ok, skill} = Claudex.Skills.create(client, "priv/skills/expense-report")

      Claudex.ToolRunner.run(client, %{
        model: "claude-opus-5",
        max_tokens: 4096,
        container: %{skills: [%{type: "custom", skill_id: skill.id, version: "latest"}]},
        tools: [%{type: "code_execution_20250825", name: "code_execution"}],
        messages: [Claudex.Message.user("Make my expense report.")]
      })

  A skill is a folder with a `SKILL.md` at its root, whose frontmatter `name`
  and `description` tell Claude what the skill is and when to use it. The
  `name` is up to 64 lowercase letters, digits and hyphens, and can't contain
  "anthropic" or "claude".

  Skills are visible to the whole workspace. `list/2` also returns Anthropic's
  own, which can be read but not deleted. Every function here answers with
  `Claudex.Skill`, and `list/2` wraps them in a `Claudex.Page`.
  """

  alias Claudex.{API, Client, Error, Page, Skill}

  @typedoc """
  The files of a skill: a directory, or `{content, path}` pairs for files that
  aren't on disk, each `path` relative to the skill, such as `"SKILL.md"` or
  `"scripts/build.py"`. A zip of the skill's folder goes up as one pair,
  `{File.read!("expense-report.zip"), "expense-report.zip"}`.
  """
  @type files :: Path.t() | [{iodata(), String.t()}]

  @typedoc """
  An option for `create/3`, described under "Options" there.
  """
  @type create_option :: {:display_name, String.t()}

  @typedoc """
  A paging option for `list/2` and `stream!/2`, described under "Options" on
  `list/2`.
  """
  @type list_option ::
          {:limit, pos_integer()} | {:page, String.t()} | {:source, String.t()}

  @doc """
  Creates a custom skill from its files.

      {:ok, skill} = Claudex.Skills.create(client, "priv/skills/expense-report")

      {:ok, skill} =
        Claudex.Skills.create(client, [
          {skill_md, "SKILL.md"},
          {File.read!("build.py"), "scripts/build.py"}
        ])

  A directory is uploaded with every file in it, at any depth, except the
  ones whose name or folder starts with a dot, such as `.git`, and the
  symlinks in it, which are skipped whatever they point at. The upload needs a
  `SKILL.md` at its root and has to stay under 30 MB.

  ## Options

    * `:display_name` - a label for the skill, up to 255 characters. Without
      it the skill takes the `name` in its `SKILL.md`.

  Raises `File.Error` if the directory, or a file in it, can't be read.
  """
  @spec create(Client.t(), files()) :: {:ok, Skill.t()} | {:error, Error.t()}
  @spec create(Client.t(), files(), [create_option()]) ::
          {:ok, Skill.t()} | {:error, Error.t()}
  def create(%Client{} = client, files, opts \\ []) do
    fields = Enum.map(skill_files(files), &file_part/1) ++ display_name_field(opts)

    with {:ok, body} <-
           API.request(client, method: :post, url: "/v1/skills", form_multipart: fields) do
      {:ok, Skill.decode(body)}
    end
  end

  @doc """
  Lists the skills in your workspace, together with Anthropic's.

      {:ok, page} = Claudex.Skills.list(client, source: "custom")

      Enum.map(page.data, & &1.display_name)
      #=> ["expense-report"]

  ## Options

    * `:limit` - how many per page, 1 to 1000. Defaults to 20.
    * `:page` - the `next_page` cursor from a previous page.
    * `:source` - `"custom"` for only your own skills, `"anthropic"` for
      only Anthropic's.

  Skills paginate with an opaque cursor: pass `page: page.next_page` for the
  next page, and stop when it's nil.
  """
  @spec list(Client.t()) :: {:ok, Page.t(Skill.t())} | {:error, Error.t()}
  @spec list(Client.t(), [list_option()]) :: {:ok, Page.t(Skill.t())} | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, body} <- API.get(client, "/v1/skills", opts) do
      {:ok, Page.decode(body, &Skill.decode/1)}
    end
  end

  @doc """
  Streams every skill `list/2` would return, however many pages that spans.

      client
      |> Claudex.Skills.stream!(source: "custom")
      |> Enum.map(& &1.display_name)

  Pages are fetched as you consume them. Takes the same options as `list/2`.
  Enumerating raises `Claudex.Error` if a request fails.
  """
  @spec stream!(Client.t()) :: Enumerable.t()
  @spec stream!(Client.t(), [list_option()]) :: Enumerable.t()
  def stream!(%Client{} = client, opts \\ []) do
    Page.stream!(opts, &list(client, &1))
  end

  @doc "Looks up one skill by its id."
  @spec retrieve(Client.t(), String.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def retrieve(%Client{} = client, skill_id) do
    with :ok <- validate_id(skill_id),
         {:ok, body} <- API.get(client, path(skill_id)) do
      {:ok, Skill.decode(body)}
    end
  end

  @doc """
  Deletes a custom skill, with every version of it. Deleted skills can't be
  recovered, and Anthropic's can't be deleted.
  """
  @spec delete(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%Client{} = client, skill_id) do
    with :ok <- validate_id(skill_id),
         {:ok, _body} <- API.delete(client, path(skill_id)) do
      :ok
    end
  end

  defp path(skill_id), do: "/v1/skills/" <> URI.encode(skill_id, &URI.char_unreserved?/1)

  defp skill_files(files) when is_list(files), do: files

  defp skill_files(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    dir_files(dir, Path.basename(dir))
  end

  defp dir_files(dir, upload_path) do
    dir
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.sort()
    |> Enum.flat_map(&entry_files(Path.join(dir, &1), Path.join(upload_path, &1)))
  end

  defp entry_files(path, upload_path) do
    case File.lstat!(path) do
      %File.Stat{type: :directory} -> dir_files(path, upload_path)
      %File.Stat{type: :regular} -> [{File.read!(path), upload_path}]
      %File.Stat{} -> []
    end
  end

  defp file_part({content, path}), do: {"files[]", {content, filename: path}}

  defp display_name_field(opts) do
    case Keyword.fetch(opts, :display_name) do
      {:ok, display_name} -> [{"display_name", display_name}]
      :error -> []
    end
  end

  defp validate_id(skill_id) when skill_id in [nil, ""] do
    {:error, %Error{type: :bad_request, message: "skill id can't be empty"}}
  end

  defp validate_id(_skill_id), do: :ok
end

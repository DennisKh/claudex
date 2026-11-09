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
  own, which can be read but not deleted. The skill functions answer with
  `Claudex.Skill`, and the version functions with `Claudex.Skill.Version`.

  ## Versions

  A skill holds one or more versions, and `version: "latest"` in a request
  runs the newest. `create_version/3` uploads a new one, which has to keep the
  skill's `name`:

      {:ok, version} = Claudex.Skills.create_version(client, skill.id, "priv/skills/expense-report")

      Claudex.Skills.delete_version(client, skill.id, version.id)

  ## The `skills-2025-10-02` beta

  The Skills API is GA and takes no beta. A client that still sends
  `skills-2025-10-02`, as the skills guide said to before GA, gets the older
  response shape these functions don't read:

    * `Claudex.Skill`'s `display_name`, `latest_version_id` and `source` come
      back nil, with no error.
    * A version is addressed by an epoch timestamp, such as
      `"1793966559318546"`, and its `skver_` id is refused.

  These functions need a client that doesn't send that beta.
  """

  alias Claudex.{API, Client, Error, Page, Skill}
  alias Claudex.Skill.Version

  @typedoc """
  The files of a skill: the path of its directory or of a `.zip` of it, or
  `{content, path}` pairs for files that aren't on disk, each `path` relative
  to the skill, such as `"SKILL.md"` or `"scripts/build.py"`.
  """
  @type files :: String.t() | [{iodata(), String.t()}]

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

  @typedoc """
  A paging option for `list_versions/3` and `stream_versions!/3`, described
  under "Options" on `list_versions/3`.
  """
  @type version_list_option :: {:limit, pos_integer()} | {:page, String.t()}

  @doc """
  Creates a custom skill from its files.

      {:ok, skill} = Claudex.Skills.create(client, "priv/skills/expense-report")

      {:ok, skill} = Claudex.Skills.create(client, "expense-report.zip")

      {:ok, skill} =
        Claudex.Skills.create(client, [
          {skill_md, "SKILL.md"},
          {File.read!("build.py"), "scripts/build.py"}
        ])

  A directory is uploaded with every file in it, at any depth, except the
  ones whose name or folder starts with a dot, such as `.git`, and the
  symlinks in it, which are skipped whatever they point at. A `.zip` goes up
  as it is: the API reads a single file as a zip only when its name ends in
  `.zip`. The upload needs a `SKILL.md` at its root and has to stay under
  30 MB, which a zip counts uncompressed.

  A create that fails after the API made the skill is retried like any other
  request, and the API takes a second skill with the same name, so a retried
  create can leave a duplicate behind.

  ## Options

    * `:display_name` - a label for the skill, up to 255 characters, with no
      line breaks or other control characters. Without it, or with `nil`, the
      skill takes its `name`.

  Raises `File.Error` if the path, or a file in it, can't be read.
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
    with :ok <- validate_id(skill_id: skill_id),
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
    with :ok <- validate_id(skill_id: skill_id),
         {:ok, _body} <- API.delete(client, path(skill_id)) do
      :ok
    end
  end

  @doc """
  Creates a new version of a custom skill from its files, which become the
  skill's latest.

      {:ok, version} = Claudex.Skills.create_version(client, skill.id, "priv/skills/expense-report")

  Takes the files the way `create/3` does. The new version's `name` has to be
  the skill's own, and a different one is refused. It is the `SKILL.md`
  frontmatter `name`, or the folder holding it when that has none. Files of earlier
  versions that the upload leaves out are not carried over.

  A request that fails after the API made the version is retried like any
  other, so a retried call can add a second version, which becomes the latest.

  Raises `File.Error` if the path, or a file in it, can't be read.
  """
  @spec create_version(Client.t(), String.t(), files()) ::
          {:ok, Version.t()} | {:error, Error.t()}
  def create_version(%Client{} = client, skill_id, files) do
    with :ok <- validate_id(skill_id: skill_id),
         fields = Enum.map(skill_files(files), &file_part/1),
         {:ok, body} <-
           API.request(client,
             method: :post,
             url: versions_path(skill_id),
             form_multipart: fields
           ) do
      {:ok, Version.decode(body)}
    end
  end

  @doc """
  Lists a skill's versions, newest first.

      {:ok, page} = Claudex.Skills.list_versions(client, skill.id)

      Enum.map(page.data, & &1.id)
      #=> ["skver_01LeSFri1iJCyMxAYxU8Y3EA", "skver_01TjyTHnwkG79a9atgLRZTLJ"]

  ## Options

    * `:limit` - how many per page, 1 to 1000. Defaults to 20.
    * `:page` - the `next_page` cursor from a previous page.
  """
  @spec list_versions(Client.t(), String.t()) ::
          {:ok, Page.t(Version.t())} | {:error, Error.t()}
  @spec list_versions(Client.t(), String.t(), [version_list_option()]) ::
          {:ok, Page.t(Version.t())} | {:error, Error.t()}
  def list_versions(%Client{} = client, skill_id, opts \\ []) do
    with :ok <- validate_id(skill_id: skill_id),
         {:ok, body} <- API.get(client, versions_path(skill_id), opts) do
      {:ok, Page.decode(body, &Version.decode/1)}
    end
  end

  @doc """
  Streams every version `list_versions/3` would return, however many pages
  that spans.

  Takes the same options as `list_versions/3`. Enumerating raises
  `Claudex.Error` if a request fails.
  """
  @spec stream_versions!(Client.t(), String.t()) :: Enumerable.t()
  @spec stream_versions!(Client.t(), String.t(), [version_list_option()]) :: Enumerable.t()
  def stream_versions!(%Client{} = client, skill_id, opts \\ []) do
    Page.stream!(opts, &list_versions(client, skill_id, &1))
  end

  @doc """
  Looks up one version of a skill, by its id or as `"latest"`.

  An Anthropic skill's version can also be named by its date, such as
  `"20261105"`, the form `Claudex.Skill.Version` says a request pins it by.
  """
  @spec retrieve_version(Client.t(), String.t(), String.t()) ::
          {:ok, Version.t()} | {:error, Error.t()}
  def retrieve_version(%Client{} = client, skill_id, version) do
    with :ok <- validate_id(skill_id: skill_id),
         :ok <- validate_id(version: version),
         {:ok, body} <- API.get(client, version_path(skill_id, version)) do
      {:ok, Version.decode(body)}
    end
  end

  @doc """
  Deletes one version of a custom skill, named by its id: `"latest"` is
  refused. Deleting the latest makes the one before it the latest.

  A skill's only version can't be deleted, and goes only with the skill,
  through `delete/2`.
  """
  @spec delete_version(Client.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_version(%Client{} = client, skill_id, version) do
    with :ok <- validate_id(skill_id: skill_id),
         :ok <- validate_id(version: version),
         {:ok, _body} <- API.delete(client, version_path(skill_id, version)) do
      :ok
    end
  end

  defp path(skill_id), do: {"/v1/skills/{skill_id}", skill_id: skill_id}

  defp versions_path(skill_id), do: {"/v1/skills/{skill_id}/versions", skill_id: skill_id}

  defp version_path(skill_id, version),
    do: {"/v1/skills/{skill_id}/versions/{version}", skill_id: skill_id, version: version}

  defp skill_files(files) when is_list(files), do: files

  defp skill_files(path) when is_binary(path) do
    path = Path.expand(path)

    if Path.extname(path) == ".zip" and File.regular?(path),
      do: [{File.read!(path), Path.basename(path)}],
      else: dir_files(path, Path.basename(path))
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
    case opts[:display_name] do
      nil -> []
      display_name -> [{"display_name", display_name}]
    end
  end

  defp validate_id([{field, id}]) when id in [nil, ""] do
    name = field |> Atom.to_string() |> String.replace("_", " ")

    {:error, %Error{type: :bad_request, message: name <> " can't be empty"}}
  end

  defp validate_id([{_field, _id}]), do: :ok
end

defmodule Claudex.Skill do
  @moduledoc """
  One Agent Skill, Anthropic's or one of your own, as `Claudex.Skills`
  returns it.

  A request names a skill by its `id`, as `type: "custom"` when `source` is
  `"custom"` and `type: "anthropic"` when it is `"anthropic"`.
  `latest_version_id` is the id of its newest version, and `display_name` is
  the `SKILL.md` frontmatter `name` unless the skill was created with a
  `:display_name`.
  """

  alias Claudex.Timestamp

  defstruct [
    :id,
    :type,
    :display_name,
    :latest_version_id,
    :source,
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          display_name: String.t(),
          latest_version_id: String.t(),
          source: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      id: json["id"],
      type: json["type"],
      display_name: json["display_name"],
      latest_version_id: json["latest_version_id"],
      source: source(json["source"]),
      created_at: Timestamp.decode(json["created_at"]),
      updated_at: Timestamp.decode(json["updated_at"])
    }
  end

  defp source(%{"type" => type}), do: type
  defp source(_source), do: nil
end

defmodule Claudex.Skill.Version do
  @moduledoc """
  One version of a skill, as the version functions of `Claudex.Skills`
  return it.

  `description` comes from the version's `SKILL.md` frontmatter, and `name`
  from its frontmatter `name`, or the folder holding it when that has none.
  The `name` is fixed when the skill is created, and every later version has
  to keep it. A request pins a version of a custom skill by its `id`.
  """

  alias Claudex.Timestamp

  defstruct [:id, :type, :skill_id, :name, :description, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          skill_id: String.t(),
          name: String.t(),
          description: String.t(),
          created_at: DateTime.t() | nil
        }

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      id: json["id"],
      type: json["type"],
      skill_id: json["skill_id"],
      name: json["name"],
      description: json["description"],
      created_at: Timestamp.decode(json["created_at"])
    }
  end
end

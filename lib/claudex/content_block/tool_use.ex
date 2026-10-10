defmodule Claudex.ContentBlock.ToolUse do
  @moduledoc """
  A request from Claude to call one of the tools you provided. Run it with
  `Claudex.Tool.call/3`, build the answer with `Claudex.Tool.result/3`, and
  send it back on your next message, matched to this block's `id`.
  `Claudex.ToolRunner` does all of that. `Claudex.Message.tool_uses/1` picks
  these out of a reply, and a tool the API runs itself arrives as a
  `Claudex.ContentBlock.ServerToolUse` instead.

  `caller` says who made the call: `%{"type" => "direct"}` for Claude itself,
  or the code execution run that called the tool from code. `toolset_name` is
  set when the tool belongs to a toolset, such as `"computer"`. Both go back
  with the block, and `Claudex.Tool.result/3` copies `toolset_name` onto the
  answer.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:id, :name, :input, :caller, :toolset_name]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map(),
          caller: map() | nil,
          toolset_name: String.t() | nil
        }

  @doc "Turns the block back into the map the API expects in a request."
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{} = block) do
    %{type: "tool_use", id: block.id, name: block.name, input: block.input}
    |> put_present(:caller, block.caller)
    |> put_present(:toolset_name, block.toolset_name)
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      id: json["id"],
      name: json["name"],
      input: json["input"] || %{},
      caller: json["caller"],
      toolset_name: json["toolset_name"]
    }
  end

  defp put_present(param, _key, nil), do: param
  defp put_present(param, key, value), do: Map.put(param, key, value)
end

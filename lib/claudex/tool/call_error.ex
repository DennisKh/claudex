defmodule Claudex.Tool.CallError do
  @moduledoc """
  Why a tool call produced no result. `Claudex.Tool.call/3` returns one, and
  `Claudex.ToolRunner` turns it into a `tool_result` with `is_error: true`.

  `message` is always a complete sentence you can show or send back to Claude,
  whatever went wrong. `details` carries the same information in a form you can
  branch on — the missing argument names, say — so reading the message never
  means parsing it.

      %Claudex.Tool.CallError{
        type: :missing_args,
        message: "missing required arguments: b",
        details: %{names: ["b"]}
      }
  """

  defstruct [:type, :message, details: %{}]

  @typedoc """
  What went wrong:

    * `:unknown_tool` — no tool of that name is registered on the module
    * `:missing_args` — a required argument wasn't in the input
    * `:tool_refused` — the tool raised `Claudex.Tool.Error`, declining on purpose
    * `:tool_raised` — anything else: another exception, a `throw`, or an `exit`
  """
  @type type :: :unknown_tool | :missing_args | :tool_refused | :tool_raised

  @type t :: %__MODULE__{type: type(), message: String.t(), details: map()}

  @doc false
  @spec unknown_tool(String.t()) :: t()
  def unknown_tool(name) do
    %__MODULE__{type: :unknown_tool, message: "no tool named #{name}", details: %{name: name}}
  end

  @doc false
  @spec missing_args([String.t()]) :: t()
  def missing_args(names) do
    %__MODULE__{
      type: :missing_args,
      message: "missing required arguments: #{Enum.join(names, ", ")}",
      details: %{names: names}
    }
  end

  @doc false
  @spec tool_refused(String.t()) :: t()
  def tool_refused(message), do: %__MODULE__{type: :tool_refused, message: message}

  @doc false
  @spec tool_raised(String.t()) :: t()
  def tool_raised(message), do: %__MODULE__{type: :tool_raised, message: message}
end

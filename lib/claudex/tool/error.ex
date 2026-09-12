defmodule Claudex.Tool.Error do
  @moduledoc """
  Raise this from a `@tool` function to refuse a call and tell Claude why.

      @doc "Reads a file from the workspace."
      @tool true
      @spec read_file(String.t()) :: String.t()
      def read_file(path) do
        unless allowed?(path), do: raise(Claudex.Tool.Error, "path is outside the workspace")

        File.read!(path)
      end

  `Claudex.ToolRunner` catches it and sends the message back as an error
  `tool_result`, so Claude sees the refusal and can try something else instead
  of the conversation ending.

  Any other exception a tool raises is also turned into an error result, but
  its content carries the exception type too — a `KeyError` from a bug in your
  tool should look different from a deliberate refusal.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}
end

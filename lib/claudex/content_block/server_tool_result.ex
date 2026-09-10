defmodule Claudex.ContentBlock.ServerToolResult do
  @moduledoc """
  What a tool the API runs itself sent back, paired to its
  `Claudex.ContentBlock.ServerToolUse` by `tool_use_id`.

  `tool` says which tool answered, and `content` is that tool's payload as the
  API sent it: a list of `web_search_result` maps for a search, a
  `web_fetch_result` wrapping a document for a fetch, a map of `stdout`,
  `stderr` and `return_code` for code execution.

      case block do
        %ServerToolResult{error_code: nil, content: results} -> render(results)
        %ServerToolResult{error_code: code} -> log(code)
      end

  A failed call is still a 200 with this block in it. `content` holds an error
  object instead of results, and `error_code` is lifted out of it so the two
  cases don't look alike.
  """

  @tools %{
    "web_search_tool_result" => :web_search,
    "web_fetch_tool_result" => :web_fetch,
    "code_execution_tool_result" => :code_execution,
    "bash_code_execution_tool_result" => :bash_code_execution,
    "text_editor_code_execution_tool_result" => :text_editor_code_execution,
    "tool_search_tool_result" => :tool_search
  }

  defstruct [:tool_use_id, :tool, :content, :error_code, :raw]

  @type tool ::
          :web_search
          | :web_fetch
          | :code_execution
          | :bash_code_execution
          | :text_editor_code_execution
          | :tool_search

  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          tool: tool(),
          content: list() | map(),
          error_code: String.t() | nil,
          raw: map()
        }

  @doc "The block types this struct decodes, as the API names them."
  @spec types() :: [String.t()]
  def types, do: Map.keys(@tools)

  @doc """
  Returns the block exactly as the API sent it.

  A search result's `encrypted_content` has to reach the next request byte for
  byte or the API rejects it, so the raw map is what gets replayed.
  """
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}), do: raw

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    content = json["content"]

    %__MODULE__{
      tool_use_id: json["tool_use_id"],
      tool: @tools[json["type"]],
      content: content,
      error_code: error_code(content),
      raw: json
    }
  end

  defp error_code(%{"error_code" => code}), do: code
  defp error_code(_content), do: nil
end

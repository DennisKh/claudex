defmodule Claudex.ContentBlock.ToolReference do
  @moduledoc """
  A pointer to one of your tools by name, which the API expands into that
  tool's full definition for Claude. A tool returns these to run a tool search
  of your own, such as one over embeddings, in place of the built-in one:

      @doc "Finds the tools that can help with a task."
      @tool true
      @spec find_tools(String.t()) :: [Claudex.ContentBlock.ToolReference.t()]
      def find_tools(task) do
        for name <- MyApp.ToolIndex.nearest(task), do: Claudex.ContentBlock.ToolReference.new(name)
      end

  Every tool named must be in the request's `tools`, normally with
  `defer_loading: true`. See
  [Custom tool search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool#custom-tool-search-implementation).
  """

  @behaviour Claudex.ContentBlock

  defstruct [:tool_name, :cache_control, :raw]

  @type t :: %__MODULE__{
          tool_name: String.t(),
          cache_control: map() | nil,
          raw: map() | nil
        }

  @typedoc """
  An option for `new/2`.

    * `:cache_control` - marks the block as a prompt-caching breakpoint, as
      on `Claudex.ContentBlock.Image`.
  """
  @type option :: {:cache_control, map()}

  @doc """
  Builds a reference to the tool named `tool_name`.

  Takes `t:option/0`.
  """
  @spec new(String.t()) :: t()
  @spec new(String.t(), [option()]) :: t()
  def new(tool_name, opts \\ []) do
    %__MODULE__{tool_name: tool_name, cache_control: Keyword.get(opts, :cache_control)}
  end

  @doc "Turns the block back into the map the API expects in a request."
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}) when is_map(raw), do: raw

  def to_param(%__MODULE__{cache_control: nil} = block) do
    %{type: "tool_reference", tool_name: block.tool_name}
  end

  def to_param(%__MODULE__{} = block) do
    %{type: "tool_reference", tool_name: block.tool_name, cache_control: block.cache_control}
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{tool_name: json["tool_name"], cache_control: json["cache_control"], raw: json}
  end
end

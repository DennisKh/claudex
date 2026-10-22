defmodule Claudex.ContentBlock.SearchResult do
  @moduledoc """
  A passage from your own sources, which Claude can cite by `source` and
  `title` the way it cites a web search. A tool returns these to answer from
  your documents:

      @doc "Searches the product docs."
      @tool true
      @spec search_docs(String.t()) :: [Claudex.ContentBlock.SearchResult.t()]
      def search_docs(query) do
        for hit <- MyApp.Docs.search(query) do
          Claudex.ContentBlock.SearchResult.new(hit.url, hit.title, hit.text, citations: true)
        end
      end

  It can also go straight into a user message. See
  [Search results](https://platform.claude.com/docs/en/build-with-claude/search-results).
  """

  @behaviour Claudex.ContentBlock

  defstruct [:source, :title, :content, :citations, :cache_control, :raw]

  @type t :: %__MODULE__{
          source: String.t(),
          title: String.t(),
          content: [map()],
          citations: map() | nil,
          cache_control: map() | nil,
          raw: map() | nil
        }

  @typedoc """
  An option for `new/4`.

    * `:citations` - `true` lets Claude cite this result. Leaving it out is
      the same as `false`. Every search result in a request has to agree, so
      it is on for all of them or for none.
    * `:cache_control` - marks the block as a prompt-caching breakpoint, as
      on `Claudex.ContentBlock.Image`.
  """
  @type option :: {:citations, boolean()} | {:cache_control, map()}

  @doc """
  Builds a search result from where it came from, its title, and its text, as
  one passage or a list of them.

      Claudex.ContentBlock.SearchResult.new("https://docs.example/a", "Setup", "Run mix setup.")

  Takes `t:option/0`.
  """
  @spec new(String.t(), String.t(), String.t() | [String.t()]) :: t()
  @spec new(String.t(), String.t(), String.t() | [String.t()], [option()]) :: t()
  def new(source, title, text, opts \\ []) do
    %__MODULE__{
      source: source,
      title: title,
      content: for(passage <- List.wrap(text), do: %{type: "text", text: passage}),
      citations: citations(Keyword.fetch(opts, :citations)),
      cache_control: Keyword.get(opts, :cache_control)
    }
  end

  @doc "Turns the block back into the map the API expects in a request."
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}) when is_map(raw), do: raw

  def to_param(%__MODULE__{} = block) do
    %{type: "search_result", source: block.source, title: block.title, content: block.content}
    |> put_present(:citations, block.citations)
    |> put_present(:cache_control, block.cache_control)
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      source: json["source"],
      title: json["title"],
      content: json["content"],
      citations: json["citations"],
      cache_control: json["cache_control"],
      raw: json
    }
  end

  defp citations({:ok, enabled}) when is_boolean(enabled), do: %{enabled: enabled}
  defp citations(:error), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

defmodule Claudex.ContentBlock.Document do
  @moduledoc """
  A document you send to Claude: a PDF, a plain text file, or content you
  assemble yourself.

      Claudex.Message.user([
        Claudex.ContentBlock.Document.file(file.id, title: "Q3 report"),
        %{type: "text", text: "What are the key findings?"}
      ])

  `pdf/2` and `text/2` embed the bytes, `url/2` points at a hosted PDF, and
  `file/2` references one uploaded through `Claudex.Files`, which is how a
  document stays out of the 32 MB request limit.

  Claude never sends one back, so this block only travels out.

  ## Options

  All four builders take:

    * `:title` - what the document is called, which Claude sees.
    * `:context` - what the document is, for Claude alone. It is not shown to
      the reader of the answer.
    * `:citations` - `true` turns on cited answers, and Claude then quotes the
      document in `Claudex.ContentBlock.Text` blocks that carry their source.
      A map goes through as the API's own citations object.
    * `:cache_control` - marks the block as a prompt-caching breakpoint,
      `%{type: "ephemeral"}` for the five-minute cache or
      `%{type: "ephemeral", ttl: "1h"}` for the hour one.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:source, :title, :context, :citations, :cache_control, :raw]

  @type source :: %{required(String.t() | atom()) => term()}

  @type t :: %__MODULE__{
          source: source(),
          title: String.t() | nil,
          context: String.t() | nil,
          citations: map() | nil,
          cache_control: map() | nil,
          raw: map() | nil
        }

  @typedoc """
  An option for `pdf/2`, `text/2`, `url/2` and `file/2`, described under
  "Options" in `Claudex.ContentBlock.Document`.
  """
  @type option ::
          {:title, String.t()}
          | {:context, String.t()}
          | {:citations, boolean() | map()}
          | {:cache_control, map()}

  @doc """
  A PDF from its bytes, already Base64-encoded.

      Claudex.ContentBlock.Document.pdf(data, title: "Q3 report", citations: true)

  Takes `t:option/0`.
  """
  @spec pdf(String.t()) :: t()
  @spec pdf(String.t(), [option()]) :: t()
  def pdf(data, opts \\ []) do
    build(%{type: "base64", media_type: "application/pdf", data: data}, opts)
  end

  @doc """
  A plain text document from the text itself.

  Takes `t:option/0`.
  """
  @spec text(String.t()) :: t()
  @spec text(String.t(), [option()]) :: t()
  def text(data, opts \\ []) do
    build(%{type: "text", media_type: "text/plain", data: data}, opts)
  end

  @doc """
  A PDF Claude fetches from `url`.

  Takes `t:option/0`.
  """
  @spec url(String.t()) :: t()
  @spec url(String.t(), [option()]) :: t()
  def url(url, opts \\ []), do: build(%{type: "url", url: url}, opts)

  @doc """
  A document already uploaded through `Claudex.Files`.

  Takes `t:option/0`.
  """
  @spec file(String.t()) :: t()
  @spec file(String.t(), [option()]) :: t()
  def file(file_id, opts \\ []), do: build(%{type: "file", file_id: file_id}, opts)

  @doc "Turns the block back into the map the API expects in a request."
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}) when is_map(raw), do: raw

  def to_param(%__MODULE__{} = block) do
    optional = [
      title: block.title,
      context: block.context,
      citations: block.citations,
      cache_control: block.cache_control
    ]

    Enum.reduce(optional, %{type: "document", source: block.source}, fn
      {_field, nil}, param -> param
      {field, value}, param -> Map.put(param, field, value)
    end)
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      source: json["source"],
      title: json["title"],
      context: json["context"],
      citations: json["citations"],
      cache_control: json["cache_control"],
      raw: json
    }
  end

  defp build(source, opts) do
    %__MODULE__{
      source: source,
      title: Keyword.get(opts, :title),
      context: Keyword.get(opts, :context),
      citations: citations(Keyword.get(opts, :citations)),
      cache_control: Keyword.get(opts, :cache_control)
    }
  end

  # The API takes an object here, and every caller wants the one field in it.
  defp citations(nil), do: nil
  defp citations(enabled) when is_boolean(enabled), do: %{enabled: enabled}
  defp citations(%{} = config), do: config
end

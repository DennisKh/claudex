defmodule Claudex.ContentBlock.Image do
  @moduledoc """
  An image you send to Claude, as one of three sources.

      Claudex.Message.user([
        Claudex.ContentBlock.Image.file(file.id),
        %{type: "text", text: "What is in this picture?"}
      ])

  `base64/3` embeds the bytes, `url/2` points at a hosted image, and `file/2`
  references one uploaded through `Claudex.Files`. JPEG, PNG, GIF and WebP are
  the formats Claude reads.

  Claude never sends one back, so this block only travels out.
  """

  @behaviour Claudex.ContentBlock

  defstruct [:source, :cache_control, :raw]

  @type source :: %{required(String.t() | atom()) => term()}

  @type t :: %__MODULE__{
          source: source(),
          cache_control: map() | nil,
          raw: map() | nil
        }

  @doc """
  An image from its bytes, already Base64-encoded.

      Claudex.ContentBlock.Image.base64(data, "image/png")
  """
  @spec base64(String.t(), String.t()) :: t()
  @spec base64(String.t(), String.t(), keyword()) :: t()
  def base64(data, media_type, opts \\ []) do
    build(%{type: "base64", media_type: media_type, data: data}, opts)
  end

  @doc "An image Claude fetches from `url`."
  @spec url(String.t()) :: t()
  @spec url(String.t(), keyword()) :: t()
  def url(url, opts \\ []), do: build(%{type: "url", url: url}, opts)

  @doc "An image already uploaded through `Claudex.Files`."
  @spec file(String.t()) :: t()
  @spec file(String.t(), keyword()) :: t()
  def file(file_id, opts \\ []), do: build(%{type: "file", file_id: file_id}, opts)

  @doc "Turns the block back into the map the API expects in a request."
  @impl true
  @spec to_param(t()) :: map()
  def to_param(%__MODULE__{raw: raw}) when is_map(raw), do: raw

  def to_param(%__MODULE__{cache_control: nil} = block) do
    %{type: "image", source: block.source}
  end

  def to_param(%__MODULE__{} = block) do
    %{type: "image", source: block.source, cache_control: block.cache_control}
  end

  @doc false
  @impl true
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{source: json["source"], cache_control: json["cache_control"], raw: json}
  end

  defp build(source, opts) do
    %__MODULE__{source: source, cache_control: Keyword.get(opts, :cache_control)}
  end
end

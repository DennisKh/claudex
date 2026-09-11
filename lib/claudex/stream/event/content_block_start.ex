defmodule Claudex.Stream.Event.ContentBlockStart do
  @moduledoc """
  A new content block is starting at `index`. The block arrives empty and its
  text, thinking, or tool input comes in the
  `Claudex.Stream.Event.ContentBlockDelta` events that follow.
  """

  alias Claudex.ContentBlock

  defstruct [:index, :content_block]

  @type t :: %__MODULE__{index: non_neg_integer(), content_block: ContentBlock.t()}

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      index: json["index"],
      content_block: ContentBlock.decode(json["content_block"] || %{})
    }
  end
end

defmodule Claudex.ToolRunner.Turn do
  @moduledoc """
  One exchange in a tool conversation: what Claude said, what it asked to run,
  and what running it produced. `Claudex.ToolRunner.stream/3` yields one of
  these per reply and `run/3` returns the last.

  `messages` carries the whole conversation up to and including this turn, so
  you can stop consuming at any point and still have the complete history from
  the last turn you saw.

  `stop` is nil while the conversation is still going, and says why it ended on
  the final turn:

    * `:completed` - Claude answered without asking for another tool.
    * `:refusal` - Claude declined. Its tool calls, if any, were not run.
    * `:max_turns` - the runner's turn limit ran out. Whatever this turn
      produced is in `messages`, tool results included, so the conversation can
      be picked up again by passing that history back.
  """

  alias Claudex.ContentBlock.ToolUse
  alias Claudex.Message

  defstruct [:message, :index, :stop, tool_uses: [], tool_results: [], messages: []]

  @type stop :: :completed | :refusal | :max_turns

  @type t :: %__MODULE__{
          message: Message.t(),
          index: pos_integer(),
          stop: stop() | nil,
          tool_uses: [ToolUse.t()],
          tool_results: [map()],
          messages: [map()]
        }

  @doc "Whether Claude asked to run anything this turn."
  @spec tool_use?(t()) :: boolean()
  def tool_use?(%__MODULE__{tool_uses: tool_uses}), do: tool_uses != []
end

defmodule Claudex.Message do
  @moduledoc """
  A completed message returned by the Messages API. `content` is a list of
  `Claudex.ContentBlock` structs, `usage` a `Claudex.Usage`, and the builders
  here turn either into the maps `Claudex.Messages.create/2` takes back.

  `raw` holds the response exactly as it arrived, so a field the API adds
  before Claudex models it is still readable. It's hidden from `inspect/1` to
  keep output readable.
  """

  alias Claudex.{ContentBlock, Usage}

  @derive {Inspect, except: [:raw]}
  defstruct [
    :raw,
    :id,
    :type,
    :model,
    :role,
    :content,
    :stop_reason,
    :stop_sequence,
    :stop_details,
    :container,
    :usage
  ]

  @type t :: %__MODULE__{
          raw: map(),
          id: String.t(),
          type: String.t(),
          model: String.t(),
          role: String.t(),
          content: [ContentBlock.t()],
          stop_reason: String.t() | nil,
          stop_sequence: String.t() | nil,
          stop_details: map() | nil,
          container: map() | nil,
          usage: Usage.t()
        }

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      raw: json,
      id: json["id"],
      type: json["type"],
      model: json["model"],
      role: json["role"],
      content: Enum.map(json["content"] || [], &ContentBlock.decode/1),
      stop_reason: json["stop_reason"],
      stop_sequence: json["stop_sequence"],
      stop_details: json["stop_details"],
      container: json["container"],
      usage: Usage.decode(json["usage"] || %{})
    }
  end

  @doc """
  Turns a decoded message back into the map the API expects in `messages`.

  `Claudex.Messages.create/2` and friends run this for you, so a
  `%Claudex.Message{}` can go straight back into the conversation:

      {:ok, reply} = Claudex.Messages.create(client, %{model: model, max_tokens: 1024, messages: history})
      history = history ++ [reply, %{role: "user", content: "and then?"}]

  A message you built yourself is passed through, with any content blocks in it
  converted too — so `user/1` and friends can take Claudex structs as content.
  """
  @spec to_param(t() | map()) :: map()
  def to_param(%__MODULE__{} = message) do
    %{role: message.role, content: Enum.map(message.content, &ContentBlock.to_param/1)}
  end

  def to_param(%{content: content} = message) when is_list(content) and not is_struct(message) do
    %{message | content: Enum.map(content, &ContentBlock.to_param/1)}
  end

  def to_param(%{} = message), do: message

  @doc """
  Adds one or more messages to the conversation.

      history = Message.append(history, Message.user("What is 12 plus 30?"))
      {:ok, reply} = Claudex.Messages.create(client, %{model: model, max_tokens: 1024, messages: history})
      history = Message.append(history, reply)

  Takes a decoded `%Claudex.Message{}` as readily as a map you built, and turns
  both into plain data on the way in. That's the point of doing it here rather
  than with `++`: a history you can hand to `JSON.encode!/1` and read back from
  a database behaves exactly like one you just built, because it's the same
  shape either way.
  """
  @spec append([map()], t() | map() | [t() | map()]) :: [map()]
  def append(history, messages) when is_list(history) and is_list(messages) do
    history ++ Enum.map(messages, &to_param/1)
  end

  def append(history, message), do: append(history, [message])

  @doc """
  Builds a user message — a question, an instruction, anything you're sending.

      Claudex.Message.user("What is 12 plus 30?")
      #=> %{role: "user", content: "What is 12 plus 30?"}

  `content` is a string for plain text, or a list of content blocks for
  anything richer — images, documents, or `Claudex.ContentBlock` structs from
  an earlier reply.
  """
  @spec user(String.t() | [map() | ContentBlock.t()]) :: map()
  def user(content), do: %{role: "user", content: content}

  @doc """
  Builds an assistant message, for putting words in Claude's mouth when you're
  replaying a conversation you stored somewhere.

  You don't need this for a reply you just received — a `%Claudex.Message{}`
  goes back into `messages` as it is.
  """
  @spec assistant(String.t() | [map() | ContentBlock.t()]) :: map()
  def assistant(content), do: %{role: "assistant", content: content}

  @doc """
  Wraps tool results into the message that carries them back to Claude.

      Claudex.Message.tool_results([Claudex.Tool.result(tool_use.id, "42")])

  Results go back with `role: "user"`, because they're input to Claude, not
  something it said. One message answers one reply: if the reply asked for
  three tools, this list holds three results, and it has to be the message
  straight after that reply. Answering only some of them is a 400 naming the
  call you left out, so a reply whose tools finish at different times sends
  nothing until the last one is in.

  `Claudex.ToolRunner` builds this message itself; this function is for a loop
  you drive.
  """
  @spec tool_results([map()]) :: map()
  def tool_results(results) when is_list(results), do: user(results)

  @doc """
  Joins every text block in the message into one string. Use this when you
  just want the reply text and don't need thinking or tool-call blocks.

      iex> message = %Claudex.Message{
      ...>   content: [
      ...>     %Claudex.ContentBlock.Text{text: "The answer "},
      ...>     %Claudex.ContentBlock.ToolUse{id: "toolu_1", name: "add", input: %{}},
      ...>     %Claudex.ContentBlock.Text{text: "is 42."}
      ...>   ]
      ...> }
      iex> Claudex.Message.text(message)
      "The answer is 42."
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: blocks}) do
    blocks
    |> Enum.filter(&match?(%ContentBlock.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  @doc """
  The tool calls in a message, in the order Claude made them.

      iex> message = %Claudex.Message{
      ...>   content: [
      ...>     %Claudex.ContentBlock.Text{text: "Let me add those."},
      ...>     %Claudex.ContentBlock.ToolUse{id: "toolu_1", name: "add", input: %{"a" => 1}}
      ...>   ]
      ...> }
      iex> Claudex.Message.tool_uses(message)
      [%Claudex.ContentBlock.ToolUse{id: "toolu_1", name: "add", input: %{"a" => 1}}]

  Empty when Claude asked for nothing, which is how a reply that ends the
  conversation reads.
  """
  @spec tool_uses(t()) :: [ContentBlock.ToolUse.t()]
  def tool_uses(%__MODULE__{content: blocks}) do
    Enum.filter(blocks, &match?(%ContentBlock.ToolUse{}, &1))
  end
end

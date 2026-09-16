defmodule Claudex.Tracing.Messages do
  @moduledoc """
  Claude's messages in the shapes a tracing backend reads.

  The conventions define `gen_ai.input.messages` and `gen_ai.output.messages`
  as a list of `%{role, parts}`, where a part is text, a tool call, or a tool
  call's response. Claude's content blocks map onto those almost one for one,
  which is what lets a backend render a Claudex trace as a conversation
  rather than a blob.

  `chat_input/2` and `chat_output/1` build a second shape for `gen_ai.prompt`
  and `gen_ai.completion`. Those attributes predate the structured model and
  have no defined shape, so what their readers expect is the chat message one:
  a role, a string of content, and tool calls under `tool_calls`. A reply
  asking for a tool would otherwise read as a reply asking for nothing.
  """

  @doc "Shapes the conversation so far into the conventions' input messages."
  @spec input([map()]) :: [map()]
  def input(messages) when is_list(messages), do: Enum.map(messages, &message/1)
  def input(_messages), do: []

  @doc """
  Shapes one reply's content blocks into a single assistant output message.
  """
  @spec output([map()] | String.t() | nil) :: [map()] | nil
  def output(nil), do: nil
  def output(content), do: [%{role: "assistant", parts: parts(content)}]

  @doc """
  Shapes the system prompt, which the conventions keep out of the chat history.

  Takes a string or the list of text blocks the API also accepts.
  """
  @spec system(String.t() | [map()] | nil) :: [map()] | nil
  def system(system) when is_binary(system), do: [%{type: "text", content: system}]

  def system(blocks) when is_list(blocks) do
    Enum.map(blocks, fn block -> %{type: "text", content: text_of(block)} end)
  end

  def system(_system), do: nil

  @doc """
  Shapes the tools the model was given into tool definitions.

  Takes what `:tools` takes, a module included: a request body has them
  expanded already, the params a conversation started with do not.
  """
  @spec definitions(module() | [module() | map()] | nil) :: [map()] | nil
  def definitions(nil), do: nil

  def definitions(tools) do
    case Claudex.Tool.list(tools) do
      [] -> nil
      expanded -> Enum.map(expanded, &definition/1)
    end
  end

  @doc """
  Shapes the conversation as chat messages, for `gen_ai.prompt`.

  That attribute predates the conventions' structured model and has no defined
  shape, so this is the one its readers parse: a flat list of messages with
  the system prompt at the front, where the conventions keep it apart.
  """
  @spec chat_input([map()], String.t() | [map()] | nil) :: [map()]
  def chat_input(messages, system) do
    system_message(system) ++ List.wrap(messages)
  end

  @doc """
  Shapes one reply as a chat message, for `gen_ai.completion`.

  Tool calls go in `tool_calls` with a name, arguments and an id. Claude sends
  them as `tool_use` content blocks, which a reader of this attribute has no
  reason to recognise, so a reply asking for a tool would read as a reply
  asking for nothing.
  """
  @spec chat_output([map()] | String.t() | nil) :: map() | nil
  def chat_output(nil), do: nil

  def chat_output(content) when is_binary(content),
    do: %{role: "assistant", content: content, tool_calls: []}

  def chat_output(blocks) when is_list(blocks) do
    %{role: "assistant", content: text_content(blocks), tool_calls: tool_calls(blocks)}
  end

  def chat_output(content), do: %{role: "assistant", content: content, tool_calls: []}

  defp system_message(nil), do: []

  defp system_message(system) do
    case system(system) do
      nil ->
        []

      instructions ->
        [%{role: "system", content: Enum.map_join(instructions, "\n", & &1.content)}]
    end
  end

  defp text_content(blocks) do
    Enum.map_join(blocks, "", fn
      %{type: "text", text: text} -> text
      %{"type" => "text", "text" => text} -> text
      _other -> ""
    end)
  end

  defp tool_calls(blocks) do
    Enum.flat_map(blocks, fn
      %{type: "tool_use", id: id, name: name, input: input} ->
        [%{type: "tool_call", id: id, name: name, args: input}]

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        [%{type: "tool_call", id: id, name: name, args: input}]

      _other ->
        []
    end)
  end

  defp message(%{role: role, content: content}), do: %{role: role, parts: parts(content)}
  defp message(%{"role" => role, "content" => content}), do: %{role: role, parts: parts(content)}
  defp message(other), do: %{role: "user", parts: parts(other)}

  defp parts(content) when is_binary(content), do: [%{type: "text", content: content}]
  defp parts(blocks) when is_list(blocks), do: Enum.map(blocks, &part/1)
  defp parts(block), do: [part(block)]

  defp part(%{type: "text", text: text}), do: %{type: "text", content: text}
  defp part(%{"type" => "text", "text" => text}), do: %{type: "text", content: text}

  defp part(%{type: "tool_use", id: id, name: name, input: input}),
    do: %{type: "tool_call", id: id, name: name, arguments: input}

  defp part(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}),
    do: %{type: "tool_call", id: id, name: name, arguments: input}

  defp part(%{type: "tool_result", tool_use_id: id} = block),
    do: %{type: "tool_call_response", id: id, response: block[:content]}

  defp part(%{"type" => "tool_result", "tool_use_id" => id} = block),
    do: %{type: "tool_call_response", id: id, response: block["content"]}

  # A block type the conventions have no part for (thinking, a server tool, an
  # image) goes through under its own name.
  defp part(%{type: type} = block), do: %{type: type, content: block}
  defp part(%{"type" => type} = block), do: %{type: type, content: block}
  defp part(block), do: %{type: "text", content: block}

  defp definition(%{name: name} = tool) do
    %{
      type: "function",
      name: name,
      description: tool[:description],
      parameters: tool[:input_schema]
    }
  end

  defp definition(%{"name" => name} = tool) do
    %{
      type: "function",
      name: name,
      description: tool["description"],
      parameters: tool["input_schema"]
    }
  end

  defp definition(tool), do: %{type: "function", name: inspect(tool)}

  defp text_of(%{text: text}), do: text
  defp text_of(%{"text" => text}), do: text
  defp text_of(block), do: block
end

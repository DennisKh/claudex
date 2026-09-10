defmodule Claudex.Messages do
  @moduledoc """
  The Messages API — send a conversation to Claude and get its reply.

  `create/2` waits for the whole reply. `stream!/2` gives you a lazy stream of
  events as they arrive, and `stream_to/3` sends those events to a process
  instead, for a GenServer or LiveView that can't block.
  """

  alias Claudex.{API, Client, Error, Message, OutputFormat, Tool}
  alias Claudex.Stream.{Connection, Forwarder, Handle}

  @required_params [:model, :messages, :max_tokens]
  @count_tokens_required_params [:model, :messages]

  @doc """
  Sends a request to `POST /v1/messages` and returns the completed message.

  `params` must include `:model`, `:messages`, and `:max_tokens`. Everything
  else the Messages API accepts (`:system`, `:temperature`, `:thinking`,
  ...) is optional and passed straight through, so any parameter the API
  supports works here — see the
  [Messages API reference](https://platform.claude.com/docs/en/api/messages).

  `:tools` takes a module that `use`s `Claudex.Tool`, a list of them, plain
  tool maps, or any mix of the two — see `Claudex.Tool.list/1`.

  `:output_config`'s `format` takes a struct module the same way, and Claude
  answers with JSON in that struct's shape — see `Claudex.OutputFormat`. A
  module whose types can't become a schema raises `Claudex.Tool.SchemaError`.

  Every other key in `params` goes into the JSON request body verbatim.

  This function always sends a non-streaming request. Passing `stream: true`
  returns `{:error, %Claudex.Error{type: :bad_request}}`,
  use `stream!/2` or `stream_to/3` instead.

  Returns `{:error, %Claudex.Error{}}` for a non-2xx response, a timeout, or
  a connection failure.
  """
  @spec create(Client.t(), map() | keyword()) :: {:ok, Message.t()} | {:error, Error.t()}
  def create(%Client{} = client, params) do
    with {:ok, body} <- build_body(params),
         :ok <- validate_not_streaming(body),
         {:ok, response} <- API.post(client, "/v1/messages", Map.put(body, :stream, false)) do
      {:ok, Message.decode(response)}
    end
  end

  @doc """
  Counts the input tokens your messages, system prompt and tools would use.
  Claude generates nothing, and the call is free — it spends a request against
  a rate limit of its own, not tokens.

      {:ok, tokens} =
        Claudex.Messages.count_tokens(client, %{
          model: "claude-opus-5",
          messages: [%{role: "user", content: "Hello, Claude"}]
        })

  Only `:model` and `:messages` are required — this endpoint has no
  `:max_tokens`, and passing one is an error from the API. Everything else
  that affects the input counts (`:system`, `:tools`, `:thinking`,
  `:tool_choice`) is optional and passed through, and `:tools` takes a module
  the same way `create/2` does.

  Server tools are rejected here with a 400. Passing `web_search` or
  `code_execution` in `:tools` fails with "Server tools are not supported in
  the count_tokens endpoint", so this cannot be used to check whether a model
  accepts a given server tool.

  The number is an estimate; a real request can come out a little different.
  """
  @spec count_tokens(Client.t(), map() | keyword()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def count_tokens(%Client{} = client, params) do
    with {:ok, body} <- build_body(params, @count_tokens_required_params),
         {:ok, response} <- API.post(client, "/v1/messages/count_tokens", body) do
      case response do
        %{"input_tokens" => count} when is_integer(count) ->
          {:ok, count}

        other ->
          {:error, Error.stream_error("the token count response had no input_tokens", other)}
      end
    end
  end

  @doc """
  Streams a reply, returning a lazy `Stream` of `Claudex.Stream.Event`
  structs.

      client
      |> Claudex.Messages.stream!(params)
      |> Enum.each(fn
        %Event.ContentBlockDelta{delta: {:text, chunk}} -> IO.write(chunk)
        _event -> :ok
      end)

  Nothing happens until you enumerate it, and enumerating owns the request:
  the process that starts consuming spawns the connection and only reads more
  of the response when you ask for the next event. Stop enumerating — with
  `Enum.take/2`, a `break`, or an exception — and the request is cancelled.

  `params` takes exactly what `create/2` takes; `stream: true` is set for
  you. Use `Claudex.Stream.final_message/1` if you want the assembled
  `Claudex.Message` at the end.

  Raises `Claudex.Error` on a missing parameter, a failed request, or an
  error the API sends part-way through the stream. Use `stream_to/3` if
  you'd rather have errors delivered as messages than raised.
  """
  @spec stream!(Client.t(), map() | keyword()) :: Enumerable.t()
  def stream!(%Client{} = client, params) do
    case build_body(params) do
      {:ok, body} -> Connection.stream(client, Map.put(body, :stream, true))
      {:error, error} -> raise error
    end
  end

  @doc """
  Runs a stream in its own process and returns straight away, delivering each
  event to a mailbox.

  `params` takes exactly what `create/2` takes; `stream: true` is set for you.

  Returns `{:ok, %Claudex.Stream.Handle{ref: ref}}` and then sends:

    * `{:claudex, ref, {:event, event}}` for each `Claudex.Stream.Event`
    * `{:claudex, ref, {:error, %Claudex.Error{}}}` if the request fails
    * `{:claudex, ref, :done}` when the reply is complete
    * `{:claudex, ref, :cancelled}` after `Claudex.Stream.cancel/1`

  The forwarding process is linked to the caller, so it dies with it. Pass
  `to: pid` to send the messages somewhere other than the calling process.
  """
  @spec stream_to(Client.t(), map() | keyword()) ::
          {:ok, Handle.t()} | {:error, Error.t()}
  @spec stream_to(Client.t(), map() | keyword(), keyword()) ::
          {:ok, Handle.t()} | {:error, Error.t()}
  def stream_to(%Client{} = client, params, opts \\ []) do
    with {:ok, body} <- build_body(params) do
      Forwarder.start(client, Map.put(body, :stream, true), opts)
    end
  end

  defp build_body(params, required \\ @required_params) do
    body =
      params |> Map.new() |> normalize_tools() |> normalize_messages() |> normalize_format()

    with :ok <- validate_required(body, required), do: {:ok, body}
  end

  defp normalize_tools(%{tools: tools} = body), do: %{body | tools: Tool.list(tools)}
  defp normalize_tools(body), do: body

  defp normalize_messages(%{messages: messages} = body) when is_list(messages) do
    %{body | messages: Enum.map(messages, &Message.to_param/1)}
  end

  defp normalize_messages(body), do: body

  defp normalize_format(%{output_config: %{format: module} = config} = body)
       when is_atom(module) and not is_nil(module) do
    %{body | output_config: %{config | format: OutputFormat.json_schema(module)}}
  end

  defp normalize_format(body), do: body

  defp validate_not_streaming(%{stream: true}) do
    {:error,
     %Error{
       type: :bad_request,
       message: "create/2 doesn't stream — drop `stream: true`, or use stream!/2 or stream_to/3"
     }}
  end

  defp validate_not_streaming(_body), do: :ok

  defp validate_required(body, required) do
    case Enum.filter(required, &(not Map.has_key?(body, &1))) do
      [] ->
        :ok

      missing ->
        {:error,
         %Error{
           type: :bad_request,
           message: "missing required params: #{Enum.join(missing, ", ")}"
         }}
    end
  end
end

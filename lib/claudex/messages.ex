defmodule Claudex.Messages do
  @moduledoc """
  The Messages API — send a conversation to Claude and get its reply.

  `create/2` waits for the whole reply. `stream!/2` gives you a lazy stream of
  events as they arrive, and `stream_to/3` sends those events to a process
  instead, for a GenServer or LiveView that can't block.
  """

  alias Claudex.{API, Client, Error, Message, Tool}
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

  `:tools` also accepts a module that `use`s `Claudex.Tool` (or a list
  mixing such modules with plain tool maps) — see `Claudex.Tool.list/1`,
  which this runs on `:tools` for you. So `tools: MyApp.Tools` works
  directly; you don't need to expand it with `Claudex.Tool.list/1` yourself.

  Every other key in `params` goes into the JSON request body verbatim.
  There's no separate channel for per-request client settings here, so
  `timeout: 5_000` would ship as a literal `"timeout"` field rather than
  shortening the request — set timeouts on the client instead
  (`Claudex.Client.new/1`).

  This function always sends a non-streaming request. Passing `stream: true`
  returns `{:error, %Claudex.Error{type: :bad_request}}` rather than quietly
  ignoring it — use `stream!/2` or `stream_to/3` instead.

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
  Counts the tokens a request would use, without sending it or being billed
  for a reply.

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

  The count covers the input only: your messages, system prompt, and tools.
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
  Streams a reply to a process as messages, for a GenServer or LiveView that
  can't sit and block on a stream.

  Returns `{:ok, %Claudex.Stream.Handle{ref: ref}}` and then sends:

    * `{:claudex, ref, {:event, event}}` for each event
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
    body = params |> Map.new() |> normalize_tools() |> normalize_messages()

    with :ok <- validate_required(body, required), do: {:ok, body}
  end

  defp normalize_tools(%{tools: tools} = body), do: %{body | tools: Tool.list(tools)}
  defp normalize_tools(body), do: body

  # A reply decodes into structs; the API wants maps. Converting here means a
  # caller can append a `%Claudex.Message{}` straight into the history instead
  # of writing the translation themselves — and can't drop a thinking block or
  # a block type Claudex doesn't model yet while doing it.
  defp normalize_messages(%{messages: messages} = body) when is_list(messages) do
    %{body | messages: Enum.map(messages, &Message.to_param/1)}
  end

  defp normalize_messages(body), do: body

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

defmodule Claudex.Tracing.Attributes do
  @moduledoc false

  # Every span name and attribute key Claudex emits, in one place. The GenAI
  # semantic conventions are still moving, so a rename lands here and nowhere
  # else. `Claudex.Tracing` owns the span mechanics; this owns the vocabulary.

  alias Claudex.{Message, Tracing}
  alias Claudex.Tracing.Messages

  @system "anthropic"
  @chat "chat"
  @execute_tool "execute_tool"
  @invoke_agent "invoke_agent"

  @doc "Names a request's span and builds its attributes, from the telemetry metadata."
  @spec request(map(), keyword()) :: {String.t(), map()}
  def request(metadata, options) do
    {name(metadata), base(metadata) |> put_request(metadata, Keyword.get(options, :json))}
  end

  @doc "Builds the attributes a response body and status add to a request's span."
  @spec response(term(), pos_integer()) :: map()
  def response(body, status) do
    %{"http.response.status_code" => status} |> Map.merge(body_attributes(body))
  end

  @doc """
  Builds the attributes a finished stream adds to its span.

  Takes `:chunks`, `:bytes`, `:started`, `:first_chunk` and `:status`. The
  first chunk is when a caller can start showing something, which no layer
  above the transport is in a position to measure.
  """
  @spec stream(map()) :: map()
  def stream(measurements) do
    %{
      "claudex.stream.events" => measurements.chunks,
      "claudex.stream.bytes" => measurements.bytes
    }
    |> put_time_to_first_chunk(measurements.first_chunk, measurements.started)
    |> put_status(measurements.status)
  end

  @doc """
  Names a conversation's span and builds its attributes.

  The conventions call this `invoke_agent`: one cycle from the request through
  the answer, with tool executions nested inside it. A tool conversation only
  reaches its answer after the loop ends, so the run is the invocation and the
  turns are steps within it.
  """
  @spec conversation(map(), pos_integer(), String.t() | nil) :: {String.t(), map()}
  def conversation(params, max_turns, session) do
    model = params[:model]

    attributes =
      %{
        "gen_ai.system" => @system,
        "gen_ai.operation.name" => @invoke_agent,
        "claudex.turn.max" => max_turns
      }
      |> put_model(model)
      |> put_session(session)
      |> put_content("gen_ai.input.messages", fn -> Messages.input(params[:messages]) end)
      |> put_content("gen_ai.system_instructions", fn -> Messages.system(params[:system]) end)
      |> put_content("gen_ai.tool.definitions", fn -> Messages.definitions(params[:tools]) end)
      |> put_content("gen_ai.prompt", fn ->
        Messages.chat_input(params[:messages], params[:system])
      end)

    {name(@invoke_agent, model), attributes}
  end

  @doc """
  Builds the attributes recording how a conversation ended, for its own span.

  A trace's input and output are the run's, not the last request's: what was
  asked at the start and what came back at the end.
  """
  @spec conversation_result(Message.t(), atom() | nil) :: map()
  def conversation_result(%Message{} = message, stop) do
    %{}
    |> put_present("claudex.stop", stop && to_string(stop))
    |> put_reply_content(message)
  end

  @doc """
  Names a turn's span and builds its attributes.

  The conventions have no operation for a step inside an invocation, so this
  is Claudex's own: a grouping span that keeps a turn's request and its tool
  calls together under the conversation they belong to.
  """
  @spec turn(pos_integer()) :: {String.t(), map()}
  def turn(index) do
    # The index stays out of the name. Span names are labels for a kind of
    # work, not for one instance of it: every turn of every run sharing one
    # name is what lets a backend fold them into a single node and count them.
    # It is also why the conventions keep ids out of names.
    #
    # No model here either. A backend infers "this is a generation" from a
    # model attribute, and a turn is a grouping span: the generation is the
    # `chat` span inside it.
    {"turn", %{"claudex.turn.index" => index}}
  end

  @doc "Names a tool call's span and builds its attributes, including its arguments."
  @spec tool(String.t(), map()) :: {String.t(), map()}
  def tool(name, input) do
    attributes =
      %{
        "gen_ai.system" => @system,
        "gen_ai.operation.name" => @execute_tool,
        "gen_ai.tool.name" => name,
        "gen_ai.tool.type" => "function"
      }
      |> put_content("gen_ai.tool.call.arguments", fn -> input end)
      |> put_content("gen_ai.prompt", fn -> input end)

    {@execute_tool <> " " <> name, attributes}
  end

  @doc """
  Builds the attributes a reply assembled from a stream adds to its span.

  The non-streaming path reads these off the response body. A streamed reply
  has no body, so nothing records the model, the token counts or the answer
  itself unless it is taken from the events.
  """
  @spec reply(Message.t()) :: map()
  def reply(%Message{} = message) do
    %{}
    |> put_present("gen_ai.response.id", message.id)
    |> put_present("gen_ai.response.model", message.model)
    |> put_usage(message.usage)
    |> put_finish_reason(message.stop_reason)
    |> put_reply_content(message)
  end

  @doc """
  Returns the error a failed tool call puts on its span, or nil when it worked.

  A tool that refuses or breaks returns rather than raising, so nothing marks
  the span and a backend's error filter passes over it.
  """
  @spec tool_error(term()) :: String.t() | nil
  def tool_error({:error, %{message: message}}), do: message
  def tool_error({:error, reason}), do: inspect(reason)
  def tool_error(_result), do: nil

  @doc "Builds the attributes recording how a tool call turned out and what it returned."
  @spec tool_outcome(atom(), term()) :: map()
  def tool_outcome(outcome, result) do
    returned = returned(result)

    %{"claudex.tool.outcome" => to_string(outcome)}
    |> put_content("gen_ai.tool.call.result", fn -> returned end)
    |> put_content("gen_ai.completion", fn -> returned end)
  end

  @doc "Returns the message a failed response sets as its span's error status."
  @spec error_message(term(), pos_integer()) :: String.t()
  def error_message(%{"error" => %{"message" => message}}, _status), do: message
  def error_message(_body, status), do: "HTTP #{status}"

  # The conventions name a generation span for the operation and the model,
  # which is what a backend reads to show it as one. Only a request that
  # generates something is one: count_tokens carries a model and generates
  # nothing, and counting it as a generation inflates every dashboard that
  # counts them.
  defp name(%{model: model, path: "/v1/messages"}), do: name(@chat, model)
  defp name(%{method: method, path: path}), do: "#{upcase(method)} #{path}"

  defp name(operation, model) when is_binary(model), do: operation <> " " <> model
  defp name(operation, _model), do: operation

  defp base(metadata) do
    %{"http.request.method" => upcase(metadata.method), "url.path" => to_string(metadata.path)}
  end

  defp put_request(attributes, %{model: model, path: "/v1/messages"}, %{} = body) do
    attributes
    |> Map.merge(%{
      "gen_ai.system" => @system,
      "gen_ai.operation.name" => @chat,
      "gen_ai.request.model" => model
    })
    |> put_present("gen_ai.request.max_tokens", body[:max_tokens])
    |> put_present("gen_ai.request.temperature", body[:temperature])
    |> put_content("gen_ai.input.messages", fn -> Messages.input(body[:messages]) end)
    |> put_content("gen_ai.system_instructions", fn -> Messages.system(body[:system]) end)
    |> put_content("gen_ai.tool.definitions", fn -> Messages.definitions(body[:tools]) end)
    |> put_content("gen_ai.prompt", fn -> Messages.chat_input(body[:messages], body[:system]) end)
  end

  defp put_request(attributes, _metadata, _body), do: attributes

  defp body_attributes(%{} = body) do
    %{}
    |> put_present("gen_ai.response.id", body["id"])
    |> put_present("gen_ai.response.model", body["model"])
    |> put_present("gen_ai.usage.input_tokens", get_in(body, ["usage", "input_tokens"]))
    |> put_present("gen_ai.usage.output_tokens", get_in(body, ["usage", "output_tokens"]))
    |> put_finish_reason(body["stop_reason"])
    |> put_content("gen_ai.output.messages", fn -> Messages.output(body["content"]) end)
    |> put_content("gen_ai.completion", fn -> Messages.chat_output(body["content"]) end)
  end

  defp body_attributes(_body), do: %{}

  defp put_usage(attributes, %{input_tokens: input, output_tokens: output}) do
    attributes
    |> put_present("gen_ai.usage.input_tokens", input)
    |> put_present("gen_ai.usage.output_tokens", output)
  end

  defp put_usage(attributes, _usage), do: attributes

  defp put_reply_content(attributes, message) do
    if Tracing.trace_content?() do
      content = Message.to_param(message).content

      attributes
      |> put_content("gen_ai.output.messages", fn -> Messages.output(content) end)
      |> put_content("gen_ai.completion", fn -> Messages.chat_output(content) end)
    else
      attributes
    end
  end

  defp put_finish_reason(attributes, nil), do: attributes

  defp put_finish_reason(attributes, reason),
    do: Map.put(attributes, "gen_ai.response.finish_reasons", [reason])

  defp put_time_to_first_chunk(attributes, nil, _started), do: attributes

  defp put_time_to_first_chunk(attributes, first_chunk, started) do
    Map.put(
      attributes,
      "claudex.stream.time_to_first_chunk_ms",
      System.convert_time_unit(first_chunk - started, :native, :millisecond)
    )
  end

  defp put_status(attributes, status) when is_integer(status),
    do: Map.put(attributes, "http.response.status_code", status)

  defp put_status(attributes, _status), do: attributes

  defp put_model(attributes, model) when is_binary(model),
    do: Map.put(attributes, "gen_ai.request.model", model)

  defp put_model(attributes, _model), do: attributes

  # `session.id` is a standard attribute rather than one backend's idea, so a
  # conversation named here groups the same way wherever the spans are sent.
  defp put_session(attributes, session) when is_binary(session),
    do: Map.put(attributes, "session.id", session)

  defp put_session(attributes, _session), do: attributes

  # A tool's arguments and result go out under two names. The conventions call
  # them `gen_ai.tool.call.arguments` and `.result`; backends read an
  # observation's input and output from `gen_ai.prompt` and `gen_ai.completion`
  # whatever the span is. Writing one would be correct and invisible, the other
  # visible and wrong.
  #
  # A span goes wherever the exporter sends it, so message content is only on
  # one when the app asked for that.
  # Elixir evaluates arguments before the call, so the shapers have to be
  # handed in unapplied: otherwise a conversation is walked and rebuilt on
  # every request of every run, and thrown away, for an app that never traces.
  defp put_content(attributes, key, build) do
    if Tracing.trace_content?(), do: put_built(attributes, key, build.()), else: attributes
  end

  defp put_built(attributes, _key, nil), do: attributes
  defp put_built(attributes, key, content), do: Map.put(attributes, key, encode(content))

  # Content is whatever a tool returned or a message carried, so encoding it
  # has to be total: a tool that reads a PNG hands back bytes JSON refuses,
  # and a span must never fail the work it measures.
  defp encode(content) when is_binary(content) do
    if String.valid?(content), do: content, else: inspect(content)
  end

  defp encode(content) do
    JSON.encode!(content)
  rescue
    _not_encodable -> inspect(content)
  catch
    _kind, _reason -> inspect(content)
  end

  # What the tool gave back, not how Claudex tagged it. `{:ok, 42}` in a trace
  # is this SDK's plumbing showing through.
  defp returned({:ok, value}), do: value
  defp returned({:error, %{message: message}}), do: message
  defp returned(result), do: result

  defp put_present(attributes, _key, nil), do: attributes
  defp put_present(attributes, key, value), do: Map.put(attributes, key, value)

  defp upcase(method), do: method |> to_string() |> String.upcase()
end

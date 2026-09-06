defmodule Claudex do
  @moduledoc """
  Elixir client for the Claude API.

  Build a client with `new/1`, then hand it to the module for whatever you're
  doing:

      client = Claudex.new(api_key: "sk-ant-...")

      {:ok, message} =
        Claudex.Messages.create(client, %{
          model: "claude-opus-5",
          max_tokens: 1024,
          messages: [%{role: "user", content: "Hello, Claude"}]
        })

      Claudex.Message.text(message)

  A client is a plain struct, so you can hold several at once and pass them
  around freely. Nothing here runs as a process or reads global state.

  ## What's here

    * `Claudex.Client` - connection settings: API key, base URL, timeouts,
      retries.
    * `Claudex.Messages` - the Messages API. `create/2` for a complete reply,
      `stream!/2` and `stream_to/3` to get it as it's written, and
      `count_tokens/2` to price a request before sending it.
    * `Claudex.Stream` - assemble a stream back into a message, or cancel one.
      `Claudex.Stream.Event` has the structs you match on while it runs.
    * `Claudex.Tool` - turn a module's functions into tools Claude can call,
      with the JSON schema derived from their `@spec` and `@doc`.
    * `Claudex.ToolRunner` - run a whole tool conversation: send, run what
      Claude asks for, send the results back, repeat.
    * `Claudex.Models` - which models your key can use, and what each supports.
    * `Claudex.Files` - upload a file once, then reference it by `file_id`
      instead of re-sending the bytes; also how you download what Claude
      creates.
    * `Claudex.Messages.Batches` - send up to 100,000 requests at once for
      asynchronous processing, at half the token cost.
    * `Claudex.Message`, `Claudex.ContentBlock`, `Claudex.Usage` - what a reply
      is made of.
    * `Claudex.Error` - every failure, with a `:type` you can match on.
    * `Claudex.Telemetry` - the events the SDK emits, and a one-line logger for
      them when you want to see what it's doing.

  Fallible functions return `{:ok, result}` or `{:error, %Claudex.Error{}}`.
  The exceptions are the `!` variants, which raise instead.
  """

  alias Claudex.Client

  @doc "Shortcut for `Claudex.Client.new/1`."
  @spec new() :: Client.t()
  @spec new(keyword()) :: Client.t()
  def new(opts \\ []), do: Client.new(opts)
end

# Claudex

[![Hex version](https://img.shields.io/hexpm/v/claudex.svg)](https://hex.pm/packages/claudex)
[![Documentation](https://img.shields.io/badge/hexdocs-claudex-purple.svg)](https://hexdocs.pm/claudex)
[![CI](https://github.com/DennisKh/claudex/actions/workflows/ci.yml/badge.svg)](https://github.com/DennisKh/claudex/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/claudex.svg)](https://github.com/DennisKh/claudex/blob/main/LICENSE)

An Elixir SDK for the [Claude API](https://platform.claude.com/docs/en/api/overview): messages, streaming, tools, files and batches.

## Installation

Add `:claudex` to your dependencies:

```elixir
def deps do
  [
    {:claudex, "~> 0.7"}
  ]
end
```

Documentation is on [HexDocs](https://hexdocs.pm/claudex).

## Quick start

```elixir
client = Claudex.new(api_key: "sk-ant-...")

{:ok, message} =
  Claudex.Messages.create(client, %{
    model: "claude-opus-5",
    max_tokens: 1024,
    messages: [Claudex.Message.user("Hello, Claude")]
  })

Claudex.Message.text(message)
#=> "Hello! How can I help you today?"
```

`Claudex.Message.user/1`, `assistant/1` and `tool_results/1` build the message maps, so you don't have to remember which role a tool result goes back under (it's `user`), and `append/2` adds them to a history. The system prompt is the `:system` request parameter rather than a message — the API rejects a `role: "system"` entry at the start of `messages`.

A failed request returns `{:error, %Claudex.Error{}}` rather than raising — see `Claudex.Error` for the full set of error types.

### API parameters

Claudex checks that `:model`, `:messages` and `:max_tokens` are there and
converts `:messages` and `:tools` for you. Every other key goes to the API
untouched, so any parameter the Messages API accepts works here, whether or not
Claudex knows about it:

```elixir
Claudex.Messages.create(client, %{
  model: "claude-opus-5",
  max_tokens: 1024,
  system: [%{type: "text", text: handbook, cache_control: %{type: "ephemeral"}}],
  tools: MyApp.Tools,
  tool_choice: %{type: "tool", name: "get_weather"},
  thinking: %{type: "adaptive"},
  messages: [Claudex.Message.user("What should I wear in New York City today?")]
})
```

Which values each one takes, and which models accept them, is Anthropic's to
say. The thinking config in particular has two shapes, and the one a model
wants depends on the model:

* [Messages API reference](https://platform.claude.com/docs/en/api/messages) for every parameter
* [Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) for `cache_control`
* [Tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview) for `tool_choice`
* [Extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking) for `thinking`

Beta features are a header rather than a parameter, so they belong to the
client: `Claudex.new(beta: ["context-management-2025-06-27"])` sends them as
one `anthropic-beta` header on every request, and `:beta` can sit in config
with the rest.

### Configuration

Connection settings can live in application config, so an app names them once:

```elixir
# config/runtime.exs
config :claudex,
  api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
  base_url: "https://api.anthropic.com",
  max_retries: 2,
  receive_timeout: :timer.minutes(10),
  connect_timeout: :timer.seconds(5),
  beta: ["context-management-2025-06-27"],
  req_options: [finch: MyApp.Finch]

client = Claudex.new()                    # picks all of that up
scoped = Claudex.new(api_key: other_key)  # one override, the rest from config
```

Anything passed to `Claudex.new/1` wins over config. `:api_key` has one more fallback below config — the `ANTHROPIC_API_KEY` environment variable — so scripts and `iex` work with nothing configured at all.

## Streaming

`stream!/2` returns a lazy stream of events. Nothing is sent until you enumerate it, and the process that enumerates owns the request — it only reads more of the response when you ask for the next event, so a slow consumer slows the download rather than filling a mailbox.

```elixir
alias Claudex.Stream.Event

client
|> Claudex.Messages.stream!(%{
  model: "claude-opus-5",
  max_tokens: 1024,
  messages: [%{role: "user", content: "Write a haiku about Erlang"}]
})
|> Enum.each(fn
  %Event.ContentBlockDelta{delta: {:text, chunk}} -> IO.write(chunk)
  _event -> :ok
end)
```

Stop enumerating (`Enum.take/2`, an exception, a `break`) and the request is cancelled. Want the finished message instead of the events? `Claudex.Stream.final_message/1` folds them back into the same `%Claudex.Message{}` a non-streaming call returns, and `Claudex.Stream.text/1` gives you just the reply text:

```elixir
{:ok, text} = client |> Claudex.Messages.stream!(params) |> Claudex.Stream.text()
```

### Streaming to a process

A GenServer or LiveView can't sit and block on a stream, so `stream_to/3` runs it in its own process and sends you messages:

```elixir
{:ok, handle} = Claudex.Messages.stream_to(client, params)

def handle_info({:claudex, ref, {:event, %Event.ContentBlockDelta{delta: {:text, chunk}}}}, socket)
    when ref == socket.assigns.handle.ref do
  {:noreply, stream_insert(socket, :chunks, chunk)}
end

def handle_info({:claudex, ref, :done}, socket), do: {:noreply, assign(socket, streaming: false)}
def handle_info({:claudex, ref, {:error, error}}, socket), do: {:noreply, put_error(socket, error)}
```

The forwarding process is linked to the caller, so it goes away with your LiveView. `Claudex.Stream.cancel/1` stops it early. Errors arrive as `{:error, %Claudex.Error{}}` messages rather than raising — that's the difference from `stream!/2`, which raises.

## Tool use

Tag a function with `@tool` and Claudex builds the JSON schema from its `@spec` and `@doc`:

```elixir
defmodule MyApp.Tools do
  use Claudex.Tool

  @doc """
  Adds two numbers and returns the sum. Use it for any arithmetic rather than
  working the answer out, so the result is always exact.
  """
  @tool true
  @spec add(number(), number()) :: number()
  def add(a, b), do: a + b

  @doc """
  Reads a UTF-8 text file and returns its contents. Use it before answering
  anything about a file's contents; it fails if the file does not exist.
  """
  @tool %{args: [path: "Absolute path, or relative to the project directory."]}
  @spec read_file(String.t()) :: String.t()
  def read_file(path), do: File.read!(path)
end

{:ok, message} =
  Claudex.Messages.create(client, %{
    model: "claude-opus-5",
    max_tokens: 1024,
    tools: MyApp.Tools,
    messages: [%{role: "user", content: "What's 12 plus 30?"}]
  })
```

The `@doc` becomes the tool's description and the `@spec` becomes its schema, so both are prompt material. `:args` adds a description per argument, merged into the inferred schema — worth writing for any argument whose name doesn't say it all, since that description is how Claude decides what to pass.

`tools:` accepts the module directly — `Claudex.Messages.create/2` expands it for you. It also accepts a list mixing modules with plain tool maps.

## Tool runner

`Claudex.ToolRunner` runs the whole back-and-forth, so you don't drive it by hand:

```elixir
{:ok, turn} =
  Claudex.ToolRunner.run(client, %{
    model: "claude-opus-5",
    max_tokens: 1024,
    tools: MyApp.Tools,
    messages: [Claudex.Message.user("What's 12 plus 30?")]
  })

Claudex.Message.text(turn.message)  # the final reply
turn.messages                       # the whole conversation
turn.stop                           # :completed | :refusal | :max_turns
```

It sends the request, runs whatever Claude asks for, sends the results back, and repeats until Claude stops asking. `turn.messages` is the whole conversation, ready to append to for the next turn — decoded Claudex structs go straight back in, no conversion. Match on `turn.stop` rather than assuming Claude finished: hitting the turn limit looks identical without it.

For one turn at a time, `stream/3` yields a `Claudex.ToolRunner.Turn` per reply and you decide when to stop:

```elixir
client
|> Claudex.ToolRunner.stream(params)
|> Enum.reduce_while(nil, fn turn, _last ->
  if interesting?(turn), do: {:cont, turn}, else: {:halt, turn}
end)
```

### Deciding whether a call runs

A tool decides for itself what it will and won't do — raise `Claudex.Tool.Error` and Claude sees the reason and adapts:

```elixir
defmodule MyApp.Tools do
  use Claudex.Tool

  @doc "Reads a file from the workspace."
  @tool true
  @spec read_file(String.t()) :: String.t()
  def read_file(path) do
    unless allowed?(path), do: raise Claudex.Tool.Error, "path is outside the workspace"

    File.read!(path)
  end
end
```

Any other exception becomes an error result too, labelled as a failure and logged, so a bug in a tool doesn't read to Claude like a policy decision and doesn't end the conversation.

When the decision belongs to the caller rather than the tool — a confirmation prompt, an allowlist, a human clicking approve — `:before_call` runs on each `tool_use` before dispatch:

```elixir
Claudex.ToolRunner.run(client, params,
  before_call: fn %Claudex.ContentBlock.ToolUse{name: name, input: input} ->
    if MyApp.Approvals.granted?(name, input) do
      :ok
    else
      {:deny, "The user declined this tool call."}
    end
  end
)
```

A denial sends the reason back as an error result and the conversation carries on, so Claude can explain itself or try another way; the tool is never called. Each call in a parallel batch is offered separately, so a batch can be partly approved. The function runs in the process enumerating the stream, so it can block — waiting on a `GenServer.call` while a LiveView shows an approve button, say.

### Showing the reply as it arrives

Every request the runner makes is a streaming one, so `:on_event` sees each `Claudex.Stream.Event` as it lands, on every turn:

```elixir
Claudex.ToolRunner.run(client, params,
  on_event: fn
    %Claudex.Stream.Event.ContentBlockDelta{delta: {:text, chunk}} -> IO.write(chunk)
    _event -> :ok
  end
)
```

It runs in the process driving the loop, one event at a time, and the next event is only read once it returns. A callback that forwards deltas to a web page streams tokens there, but the turn still ends if the process driving the loop stops.

The loop blocks the process it runs in, so a LiveView or a GenServer runs it in a task and lets `:on_event` send the deltas back, tagged with a ref:

```elixir
ref = make_ref()
parent = self()

Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
  Claudex.ToolRunner.run(client, params, on_event: &send(parent, {:reply, ref, &1}))
end)
```

Matching that ref where the messages arrive keeps a reply from a conversation the user has left out of the one on screen:

```elixir
def handle_info({:reply, ref, event}, %{assigns: %{ref: ref}} = socket)
def handle_info({:reply, _stale, _event}, socket), do: {:noreply, socket}
```

The conversation ends with the task, so `:before_call` fits a decision the user makes now. One that arrives in a later request needs storing, and the loop re-entered from there.

If you'd rather drive the loop yourself, `Claudex.Tool.call/3` runs one tool and `Claudex.Tool.result/3` builds the block to send back.

A struct or Ecto schema in a `@spec` (`@spec summarize(Ticket.t()) :: String.t()`) expands into a nested object schema automatically. A type Claudex can't map raises `Claudex.Tool.SchemaError` at compile time; pass `args_schema:` in the `@tool` options to describe it yourself. See the `Claudex.Tool` and `Claudex.Tool.Schema.StructExpansion` module docs for the full picture.

## Rebuilding a conversation from your own storage

`Claudex.Message.append/2` suits a script that keeps the whole conversation in
memory. An app that persists each turn rebuilds the request from its own rows
instead, and there are helpers for every block it has to put back:

```elixir
def to_request(rows) do
  Enum.map(rows, fn
    %{role: "user", text: text} ->
      Claudex.Message.user(text)

    %{role: "assistant", text: text, tool_calls: calls} ->
      Claudex.Message.assistant(
        [%Claudex.ContentBlock.Text{text: text}] ++
          Enum.map(calls, fn call ->
            %Claudex.ContentBlock.ToolUse{id: call.id, name: call.name, input: call.input}
          end)
      )

    %{role: "tool_results", results: results} ->
      Claudex.Message.tool_results(
        Enum.map(results, &Claudex.Tool.result(&1.call_id, &1.output, is_error: &1.failed?))
      )
  end)
end
```

`Claudex.Tool.result/3` builds a `tool_result` block, and `Message.tool_results/1`
wraps them in the `role: "user"` message the API expects. Build
`Claudex.ContentBlock` structs rather than hand-writing `%{type: "tool_use", ...}`
maps. `Claudex.Messages.create/2` turns a struct into the map the API expects on
the way out, and `Claudex.ContentBlock.to_param/1` does the same for one block if
you need it before then.

Two things to store alongside the text. A `tool_use` block needs its `id`, since
the matching `tool_result` refers to it. A `thinking` block needs its
`signature`, because continuing a thinking conversation on the same model means
sending prior thinking blocks back intact.

Results for one reply go back together. If a reply asked for two tools, the
next message has to answer both:

```elixir
[call_a, call_b] = Claudex.Message.tool_uses(turn.message)

Claudex.Message.tool_results([
  Claudex.Tool.result(call_a.id, "42"),
  Claudex.Tool.result(call_b.id, "7")
])
```

Answering only `call_a` is a 400, and it names the call you left out.
"Immediately after" is literal: the results have to be the very next message,
not a later one. An app that waits on a human to approve one of the calls
therefore holds them all until the last one resolves, rather than sending the
results it has so far.

## Telemetry and logging

Claudex writes nothing to your logs on its own. It emits `:telemetry` events, and ships a logger you can turn on in one line while debugging:

```elixir
Claudex.Telemetry.attach_default_logger()
```

```
[debug] claudex POST /v1/messages claude-opus-5 → 200 in 890.4ms (8 in / 16 out) request_id=req_011CQ...
[debug] claudex POST /v1/messages claude-opus-5 → 200 in 6531.5ms, streamed 4821 B in 10 chunk(s) request_id=req_011CQ...
[debug] claudex tool add → ok in 0.1ms
[debug] claudex tool_runner turn 1 → 1 tool call(s)
[debug] claudex tool_runner finished after 2 turn(s): completed
```

Streaming and non-streaming report the same `[:claudex, :request, :*]` span; a
streamed one adds the chunk and byte counts. Token counts arrive in the
response body, so a streamed span has none — read `usage` off the message from
`Claudex.Stream.final_message/1`.

Every line carries the Logger domain `[:elixir, :claudex]`, so an application
can tell them apart from its own — useful in a Phoenix app, where Ecto and
LiveView fill the same `[debug]` stream. To see only Claudex's:

```elixir
:logger.add_primary_filter(
  :claudex_only,
  {&:logger_filters.domain/2, {:stop, :not_equal, [:elixir, :claudex]}}
)
```

`Claudex.Telemetry.detach_default_logger/0` turns it off. For production, attach your own handler with `:telemetry.attach_many/4` and send the events to metrics or tracing instead.

The events cover the things you can't otherwise see: the model and `request_id` behind each call (Claudex keeps the request id only on errors), tool outcomes, why a tool conversation stopped, and retries Claudex *declined* because part of a response had already been delivered. Metadata carries model names, status, token counts, durations and tool names — never prompts, completions, tool arguments, or anything from your client.

## Models and token counting

```elixir
{:ok, page} = Claudex.Models.list(client, limit: 5)
Enum.map(page.data, & &1.id)
#=> ["claude-opus-5", "claude-sonnet-5", ...]

{:ok, model} = Claudex.Models.retrieve(client, "claude-opus-latest")
model.id           #=> "claude-opus-5"
model.max_tokens   #=> 128000
```

`list/2` returns one `%Claudex.Page{}`. If `page.has_more` is true, pass `after_id: page.last_id` for the next one.

To find out what a request will cost before sending it:

```elixir
{:ok, tokens} =
  Claudex.Messages.count_tokens(client, %{
    model: "claude-opus-5",
    messages: [%{role: "user", content: "Hello, Claude"}]
  })
```

This endpoint takes `:model` and `:messages` — no `:max_tokens` — and counts the input only: your messages, system prompt, and tools. `:tools` accepts a module here too.

## Files

Upload a file once and reference it by `file_id` instead of re-sending the bytes on every request:

```elixir
{:ok, file} = Claudex.Files.upload(client, "report.pdf")

Claudex.Messages.create(client, %{
  model: "claude-opus-5",
  max_tokens: 1024,
  messages: [%{role: "user", content: [
    %{type: "document", source: %{type: "file", file_id: file.id}},
    %{type: "text", text: "Summarise this."}
  ]}]
})
```

Images and PDFs don't *need* this — inline base64 and URL sources work today, because `create/2` passes content blocks through verbatim. Files saves upload time and request size (500 MB per file vs. the 32 MB request limit), not tokens: the content still enters the context window and is still billed.

`download/2` is the other direction, and the part with no inline equivalent — it retrieves files Claude *created* through skills or the code execution tool. Files you uploaded have `downloadable: false` and downloading one returns a 400.

`list/2` pages by cursor rather than by id: pass `page: page.next_page` until it comes back nil.

## Message batches

Send up to 100,000 requests at once, asynchronously, at half the token cost:

```elixir
{:ok, batch} = Claudex.Messages.Batches.create(client, [
  %{custom_id: "ticket-1", params: %{model: "claude-opus-5", max_tokens: 1024,
                                     messages: [%{role: "user", content: "..."}]}}
])

# later, from a job runner
{:ok, batch} = Claudex.Messages.Batches.retrieve(client, batch.id)

if Claudex.Messages.Batch.ended?(batch) do
  {:ok, results} = Claudex.Messages.Batches.results(client, batch.id)

  Enum.each(results, fn
    %{custom_id: id, result: {:ok, message}} -> store(id, message)
    %{custom_id: id, result: {:error, error}} -> log(id, error)
    %{custom_id: id, result: :expired} -> requeue(id)
    %{result: :canceled} -> :ok
  end)
end
```

Claudex doesn't poll for you. A batch has 24 hours to finish, so check on it from your app's job runner with the batch id persisted.

`results/2` returns a lazy stream that reads the `.jsonl` as it goes, so a 100,000-request batch doesn't have to fit in memory. Results arrive in completion order, not request order — match them by `custom_id`.

## Development

```
mix deps.get
mix test              # unit tests — no network, no API key needed
mix format
mix credo --strict
mix dialyzer
```

### Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull request: format check, `--warnings-as-errors` compile, Credo strict, the offline test suite, and Dialyzer. It makes no API calls and needs no key — the live suite is tagged `:live` and excluded by `test/test_helper.exs`.

The workflow pins Elixir and OTP explicitly, so a CI run doesn't drift from the versions the library is tested against.

### End-to-end evals

`test/claudex/live/` runs real requests against the Claude API, one file per capability:

| File | Covers |
|---|---|
| `messages_live_test.exs` | `create/2`, multi-turn context |
| `streaming_live_test.exs` | `stream!/2`, `stream_to/3`, `cancel/1` mid-stream |
| `tools_live_test.exs` | tool call → dispatch → `tool_result` → follow-up, parallel calls |
| `thinking_live_test.exs` | thinking blocks, streamed and not |
| `caching_live_test.exs` | `cache_control`, cache write and read token counts |
| `errors_live_test.exs` | 404, 400, 401, and `count_tokens` rejecting `max_tokens` |
| `models_live_test.exs` | list, paging, alias resolution, `count_tokens` |
| `files_live_test.exs` | upload, metadata, list, download refusal, delete |
| `batches_live_test.exs` | create, retrieve, cancel, list, results-not-ready |
| `tool_runner_live_test.exs` | `run/3` and `stream/3` against real tool calls |

They're tagged `:live` and excluded from `mix test` (network + cost). To run them locally, export a real key first:

```
export ANTHROPIC_API_KEY=sk-ant-...
mix test.live
```

In CI they are a separate, manually triggered workflow — **Actions → Live evals → Run workflow** — never part of the normal pipeline, because every run costs money. It runs every eval in `test/claudex/live/` and nothing else — CI has already run the offline suite — and an optional `file` input narrows it to one file. It needs an `ANTHROPIC_API_KEY` repository secret, and fails immediately if that secret is missing rather than skipping every test and reporting success.

### Releases

`.github/workflows/release-please.yml` keeps a release pull request open, built from the [conventional commits](https://www.conventionalcommits.org/) on `main`. Merging it bumps the version in `mix.exs`, writes `CHANGELOG.md`, and tags the release. Publishing to Hex is a separate `mix hex.publish` from a tagged commit.

### Fixtures

`mix test.record` runs the same live suite and saves what the API sent into `test/fixtures/` — JSON responses, and raw `.sse` transcripts byte-for-byte off the wire. `test/claudex/replay_test.exs` then replays those offline as part of the normal `mix test` run, including re-chunking the SSE at 1, 7, 64, and 4096 bytes to prove the decoder doesn't care where the boundaries fall.

The fast suite therefore runs against payloads the API really sent. Fixtures are committed, so `git diff test/fixtures/` after a re-record shows exactly what changed on the API side.

## License

MIT — see [LICENSE](LICENSE).

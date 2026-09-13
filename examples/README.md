# Examples

Standalone Mix projects that use Claudex the way an application would. Each one
depends on the SDK by path, so it builds against the working copy you have
checked out rather than a published version.

Nothing here is part of the `claudex` Hex package, and nothing here is compiled,
formatted, or analysed by the SDK's own `mix` tasks. They are read and run on
their own.

## arithmetix

A tool conversation with a hard stop. Claude is given an arithmetic expression
and one tool per operation, and has to work through it a step at a time; a
`finish` tool marks the end, and the example halts on it rather than waiting for
the model to stop asking. The expression divides by zero on purpose, so the run
also shows a tool refusing a call.

It demonstrates:

* deriving a tool's schema from its `@doc` and `@spec` with `Claudex.Tool`
* refusing a call by raising `Claudex.Tool.Error`, and what Claude does next
* driving the loop with `Claudex.ToolRunner.stream/3` and `Enum.reduce_while/3`
* forcing a tool call every turn with `tool_choice: %{type: "any"}`
* the request and tool log from `Claudex.Telemetry.attach_default_logger/0`

### Running it

You need an API key. The run costs a few hundred tokens against
`claude-haiku-4-5`.

```sh
cd examples/arithmetix
mix deps.get
export ANTHROPIC_API_KEY=sk-ant-...
mix run -e "Arithmetix.run()"
```

`mix deps.get` resolves `{:claudex, path: "../.."}` to the SDK in this
repository, so a change you make to `lib/` shows up on the next run.

The output is the SDK's own debug log for each request and tool call, then a
trace of the conversation, then the final answer:

```
[debug] claudex POST /v1/messages claude-haiku-4-5 → 200 in 1628.7ms, streamed 3668 B in 10 chunk(s)
[debug] claudex tool add → ok in 1.8ms
[debug] claudex tool_runner turn 1 → 1 tool call(s)
...
─── Full trace ───
[User] Compute (5+3)*2 - 6/0
[AI Message] I need to solve this step by step following BODMAS rules.
[Tool Call] name: add, input: %{"a" => 5, "b" => 3}
[Tool Result] 8
...
─── Final answer ───
```

Change `@task` in `lib/arithmetix.ex` to give it a different expression.

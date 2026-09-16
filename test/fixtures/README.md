# Fixtures

Every file here was captured from a real response by `Claudex.TestSupport.Recorder`
(`test/support/recorder.ex`), which a live test attaches to its client with
`Recorder.record_json/2` or `Recorder.record_stream/2` and `mix test.record` turns on.
None of these were hand-written. `test/claudex/replay_test.exs` replays them
back through the decoders, so a fixture going stale shows up there as a
failing decode.

All thirteen were added in one commit, `88bf1b5` (2026-09-08,
"test: replay recorded API payloads in the offline suite (#19)"); git history
carries no earlier or later capture for any of them. A few fixtures embed
their own `created_at`, which is the request's real timestamp rather than a
guess; the rest carry no timestamp of their own, so the commit date is the
only dated record of when they entered the repo. Every one names
`claude-haiku-4-5-20251001` as `model` (or, for the Models endpoints, as the
id looked up) — the live suite's `@model` alias resolves to `claude-haiku-4-5`
at the time of capture.

| File | Endpoint | Live test | Captured |
| --- | --- | --- | --- |
| `message.json` | `POST /v1/messages` | `live/messages_live_test.exs` — "gets a real reply from the Messages API" | commit date only |
| `message_stream.sse` | `POST /v1/messages` (`stream: true`) | `live/streaming_live_test.exs` — "stream!/2 yields real events that reassemble into the message" | commit date only |
| `cached.json` | `POST /v1/messages`, with a `cache_control` system block | `live/caching_live_test.exs` — "reports cache writes and reads in usage" | commit date only |
| `thinking.json` | `POST /v1/messages`, with `thinking: %{type: "enabled", ...}` | `live/thinking_live_test.exs` — "returns thinking blocks alongside the reply" | commit date only |
| `thinking_stream.sse` | `POST /v1/messages` (`stream: true`), with `thinking` enabled | `live/thinking_live_test.exs` — "streams thinking deltas and the signature that closes the block" | commit date only |
| `tool_use.json` | `POST /v1/messages`, with `tools` and a forced `tool_choice` | `live/tools_live_test.exs` — "round-trips a tool call: request, dispatch, and follow-up" | commit date only |
| `error_400.json` | `POST /v1/messages`, `max_tokens` set far too high | `live/errors_live_test.exs` — "an out-of-range max_tokens is a bad-request error" | commit date only |
| `error_404.json` | `GET /v1/models/{id}`, an id that doesn't exist | `live/errors_live_test.exs` — "an unknown model id is a not-found error" | commit date only |
| `model.json` | `GET /v1/models/{id}` | `live/models_live_test.exs` — "resolves an alias to a concrete model id" | commit date only |
| `models_page.json` | `GET /v1/models` | `live/models_live_test.exs` — "lists models and pages through them" | commit date only |
| `file.json` | `POST /v1/files` | `live/files_live_test.exs` (setup) — uploads the file every test in that module shares | `created_at` in the fixture: `2026-09-04T23:23:04.285973Z` |
| `files_page.json` | `GET /v1/files` | `live/files_live_test.exs` — "lists files with the cursor the Files API actually uses" | `created_at` in the fixture: `2026-09-04T23:23:04.285973Z` (same uploaded file) |
| `batch.json` | `POST /v1/messages/batches` | `live/batches_live_test.exs` — "submits a batch, reads it back, and cancels it" | `created_at` in the fixture: `2026-09-04T23:19:44.604104+00:00` |

"Commit date only" means the fixture carries no timestamp of its own; the
earliest and only record of when it was captured is `88bf1b5`'s commit date,
2026-09-08. The three files with an embedded `created_at` were captured a few
days before that commit landed, which is consistent with local iteration
before the PR was opened — but that is what the data shows, not something
this file asserts beyond it.

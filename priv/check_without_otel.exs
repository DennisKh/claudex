# Run by `mix test.no_otel` in an environment with no dev or test
# dependencies, so Claudex has only opentelemetry_api, which is what a
# consumer has.
if Application.spec(:opentelemetry, :vsn) do
  IO.puts("the OpenTelemetry SDK is loaded, so this checks nothing")
  System.halt(1)
end

checks = [
  {"span/2 returns the work's value", fn -> Claudex.Tracing.span(fn -> {"x", %{}} end, fn _span -> :work end) == :work end},
  {"enabled? is false", fn -> Claudex.Tracing.enabled?() == false end},
  {"recording? is false", fn -> Claudex.Tracing.recording?() == false end},
  {"trace_content? is false", fn -> Claudex.Tracing.trace_content?() == false end},
  {"attach/1 accepts a context", fn -> Claudex.Tracing.attach(Claudex.Tracing.context()) == :ok end},
  {"set_attributes/2", fn -> Claudex.Tracing.set_attributes(Claudex.Tracing.current_span(), %{}) == :ok end},
  {"set_error/2", fn -> Claudex.Tracing.set_error(:untraced, "nope") == :ok end},
  {"start_span/1 and end_span/1", fn -> (fn -> {"x", %{}} end) |> Claudex.Tracing.start_span() |> Claudex.Tracing.end_span() == :ok end}
]

defmodule Stub do
  @reply %{
    "id" => "msg_1",
    "type" => "message",
    "role" => "assistant",
    "model" => "claude-haiku-4-5",
    "content" => [%{"type" => "text", "text" => "42"}],
    "stop_reason" => "end_turn",
    "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
  }

  def run(request), do: {request, Req.Response.new(status: 200, body: @reply)}
end

request_check =
  {"a real request runs the tracing path without an SDK",
   fn ->
     client = Claudex.Client.new(api_key: "sk", max_retries: 0, req_options: [adapter: Stub])

     case Claudex.Messages.create(client, %{
            model: "claude-haiku-4-5",
            max_tokens: 16,
            messages: [%{role: "user", content: "hi"}]
          }) do
       {:ok, message} -> Claudex.Message.text(message) == "42"
       _other -> false
     end
   end}

checks = checks ++ [request_check]

failed =
  Enum.reduce(checks, [], fn {name, check}, failed ->
    result = try do: check.(), rescue: (error -> {:raised, error.__struct__})

    IO.puts("  #{if result == true, do: "ok  ", else: "FAIL"} #{name}#{unless result == true, do: " -> #{inspect(result)}"}")

    if result == true, do: failed, else: [name | failed]
  end)

if failed == [], do: IO.puts("\ntracing is inert without the SDK"), else: System.halt(1)

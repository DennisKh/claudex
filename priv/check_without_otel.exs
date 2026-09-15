# Run by `mix test.no_otel` in an environment with no dev or test
# dependencies, so Claudex has only opentelemetry_api, which is what a
# consumer has.
if Application.spec(:opentelemetry, :vsn) do
  IO.puts("the OpenTelemetry SDK is loaded, so this checks nothing")
  System.halt(1)
end

checks = [
  {"span/3 returns the work's value", fn -> Claudex.Tracing.span("x", %{}, fn -> :work end) == :work end},
  {"recording? is false", fn -> Claudex.Tracing.recording?() == false end},
  {"trace_content? is false", fn -> Claudex.Tracing.trace_content?() == false end},
  {"attach/1 accepts a context", fn -> Claudex.Tracing.attach(Claudex.Tracing.context()) == :ok end},
  {"set_attributes/1", fn -> Claudex.Tracing.set_attributes(%{"a" => 1}) == :ok end},
  {"set_attributes/2", fn -> Claudex.Tracing.set_attributes(Claudex.Tracing.current_span(), %{}) == :ok end},
  {"set_error/1", fn -> Claudex.Tracing.set_error("nope") == :ok end},
  {"start_span/2 and end_span/1", fn -> "x" |> Claudex.Tracing.start_span(%{}) |> Claudex.Tracing.end_span() == :ok end}
]

failed =
  Enum.reduce(checks, [], fn {name, check}, failed ->
    result = try do: check.(), rescue: (error -> {:raised, error.__struct__})

    IO.puts("  #{if result == true, do: "ok  ", else: "FAIL"} #{name}#{unless result == true, do: " -> #{inspect(result)}"}")

    if result == true, do: failed, else: [name | failed]
  end)

if failed == [], do: IO.puts("\ntracing is inert without the SDK"), else: System.halt(1)

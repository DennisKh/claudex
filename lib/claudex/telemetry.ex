defmodule Claudex.Telemetry do
  @moduledoc """
  Events Claudex emits, and a ready-made logger for them.

  Claudex writes nothing to your logs on its own. It emits `:telemetry` events,
  and you decide what happens to them. To see what the SDK is doing while
  you're debugging, attach the logger that ships with it:

      Claudex.Telemetry.attach_default_logger()

  That's it — no config, no compile flags. Turn it off with
  `detach_default_logger/0`. For anything beyond development, attach your own
  handler with `:telemetry.attach_many/4` and send the events wherever they
  belong.

  ## What's in an event, and what isn't

  Metadata carries model names, HTTP status, request ids, token counts,
  durations, tool names, and turn numbers. It never carries prompts,
  completions, tool arguments, tool results, or anything from your client —
  logs get shipped to places conversations shouldn't go, and an API key should
  never be one keystroke from a log line.

  ## Events

  ### `[:claudex, :request, :start | :stop | :exception]`

  A span around one HTTP request. Metadata has `:method` and `:path`
  throughout, `:model` when the request names one, and on `:stop` also
  `:status`, `:request_id`, and — when the response carries usage —
  `:input_tokens` and `:output_tokens`. The request id is worth capturing: it's
  what Anthropic support asks for, and Claudex otherwise keeps it only on
  errors.

  ### `[:claudex, :retry, :declined]`

  A retry that Claudex refused because part of the response had already reached
  the caller — retrying would replay output and bill twice. Req logs the
  retries it makes; without this, the ones we decline look like nothing
  happened.

  ### `[:claudex, :tool, :start | :stop | :exception]`

  A span around one tool call. `:stop` metadata has `:tool` and an `:outcome`
  of `:ok`, `:refused`, `:failed`, or `:unknown_tool`.

  ### `[:claudex, :tool_runner, :turn]` and `[:claudex, :tool_runner, :stop]`

  One event per reply in a tool conversation, and one when the loop ends
  carrying `:stop` — `:completed`, `:refusal`, or `:max_turns`.
  """

  require Logger

  @handler_id "claudex-default-logger"

  @events [
    [:claudex, :request, :stop],
    [:claudex, :request, :exception],
    [:claudex, :retry, :declined],
    [:claudex, :tool, :stop],
    [:claudex, :tool_runner, :turn],
    [:claudex, :tool_runner, :stop]
  ]

  @doc "The events Claudex emits."
  @spec events() :: [[atom()]]
  def events do
    @events ++
      [
        [:claudex, :request, :start],
        [:claudex, :stream, :start],
        [:claudex, :tool, :start],
        [:claudex, :tool, :exception]
      ]
  end

  @doc """
  Logs Claudex's events, for when you want to see what the SDK is doing.

  Takes `:level`, defaulting to `:debug`. Attaching twice is a no-op.
  """
  @spec attach_default_logger() :: :ok
  @spec attach_default_logger(keyword()) :: :ok
  def attach_default_logger(opts \\ []) do
    config = %{level: Keyword.get(opts, :level, :debug)}

    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, config) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Stops the logger `attach_default_logger/1` started."
  @spec detach_default_logger() :: :ok
  def detach_default_logger do
    case :telemetry.detach(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc false
  def handle_event([:claudex, :request, :stop], measurements, metadata, config) do
    log(config, fn ->
      "#{method(metadata)} #{metadata.path}#{model(metadata)} → #{metadata[:status]} " <>
        "in #{ms(measurements)}ms" <>
        streamed(measurements) <> tokens(metadata) <> request_id(metadata)
    end)
  end

  def handle_event([:claudex, :request, :exception], measurements, metadata, config) do
    log(config, fn ->
      "#{method(metadata)} #{metadata.path} raised #{inspect(metadata[:kind])} " <>
        "after #{ms(measurements)}ms"
    end)
  end

  def handle_event([:claudex, :retry, :declined], _measurements, metadata, config) do
    log(config, fn -> "retry declined: #{metadata.reason}" end)
  end

  def handle_event([:claudex, :tool, :stop], measurements, metadata, config) do
    log(config, fn -> "tool #{metadata.tool} → #{metadata.outcome} in #{ms(measurements)}ms" end)
  end

  def handle_event([:claudex, :tool_runner, :turn], measurements, metadata, config) do
    log(config, fn ->
      "tool_runner turn #{metadata.index} → #{measurements.tool_calls} tool call(s)"
    end)
  end

  def handle_event([:claudex, :tool_runner, :stop], measurements, metadata, config) do
    log(config, fn ->
      "tool_runner finished after #{measurements.turns} turn(s): #{metadata.stop}"
    end)
  end

  defp log(%{level: level}, message) do
    # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
    Logger.log(level, fn -> "claudex " <> message.() end, domain: [:claudex])
  end

  defp streamed(%{chunks: chunks, bytes: bytes}),
    do: ", streamed #{bytes} B in #{chunks} chunk(s)"

  defp streamed(_measurements), do: ""

  defp method(metadata), do: metadata |> Map.get(:method, :get) |> to_string() |> String.upcase()

  defp model(%{model: model}) when is_binary(model), do: " #{model}"
  defp model(_metadata), do: ""

  defp ms(%{duration: duration}) do
    duration |> System.convert_time_unit(:native, :microsecond) |> div(100) |> Kernel./(10)
  end

  defp ms(_measurements), do: "?"

  defp tokens(%{input_tokens: input, output_tokens: output})
       when is_integer(input) and is_integer(output) do
    " (#{input} in / #{output} out)"
  end

  defp tokens(_metadata), do: ""

  defp request_id(%{request_id: id}) when is_binary(id), do: " request_id=#{id}"
  defp request_id(_metadata), do: ""
end

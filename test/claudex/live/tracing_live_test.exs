defmodule Claudex.Live.TracingTest do
  @moduledoc """
  What the spans actually carry when the calls are real.

  A stub answers with whatever a test wrote into it, so it can confirm a value
  is copied onto a span but never that the value was right. These check the
  things only the API can settle: that a snapshot model id differs from the
  alias asked for, that token counts and stop reasons are the API's own, and
  that a refused request marks the span with the message the API sent.

  Spans are exported to the test process rather than to a collector, so the
  assertions are on what was recorded and not on the call that recorded it.
  """

  use Claudex.TestSupport.LiveCase, async: false

  require Record

  alias Claudex.{Message, Messages, Models, ToolRunner}

  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  @system "You are a calculator. Use the provided tools for every calculation, " <>
            "and answer with the number alone."

  defmodule Calculator do
    @moduledoc false
    use Claudex.Tool

    @doc "Adds two integers together."
    @tool true
    @spec add(integer(), integer()) :: integer()
    def add(a, b), do: a + b

    @doc "Divides the first integer by the second."
    @tool true
    @spec divide(integer(), integer()) :: integer()
    def divide(_a, 0), do: raise(Claudex.Tool.Error, "cannot divide by zero")
    def divide(a, b), do: div(a, b)
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> Application.delete_env(:claudex, :trace_content) end)

    :ok
  end

  describe "a real tool conversation" do
    test "is one trace, with the API's own model, tokens and stop reason", %{client: client} do
      params = %{
        model: @model,
        max_tokens: 512,
        system: @system,
        tools: Calculator,
        messages: [Message.user("What is 12 plus 30?")]
      }

      assert {:ok, turn} = ToolRunner.run(client, params, session: "claudex-live-tracing")
      assert Message.text(turn.message) =~ "42"

      spans = collect([])

      assert spans |> Enum.map(&span(&1, :trace_id)) |> Enum.uniq() |> length() == 1
      assert [root] = Enum.filter(spans, &(span(&1, :parent_span_id) == :undefined))
      assert span(root, :name) == "invoke_agent " <> @model
      assert attributes(root)["session.id"] == "claudex-live-tracing"
      assert attributes(root)["claudex.stop"] == "completed"

      requests = named(spans, "chat " <> @model)
      assert requests != []

      for request <- requests do
        recorded = attributes(request)

        # A request naming an alias comes back naming a snapshot. Only the API
        # can tell us the two differ, and a trace that kept one of them could
        # not say which model answered.
        assert recorded["gen_ai.request.model"] == @model
        assert recorded["gen_ai.response.model"] =~ ~r/^#{@model}-\d{8}$/
        assert recorded["gen_ai.response.model"] != recorded["gen_ai.request.model"]

        # A streamed reply has no response body, so every one of these was read
        # back from the events.
        assert recorded["gen_ai.usage.input_tokens"] > 0
        assert recorded["gen_ai.usage.output_tokens"] > 0
        assert [reason] = recorded["gen_ai.response.finish_reasons"]
        assert reason in ["end_turn", "tool_use", "max_tokens"]
        assert String.starts_with?(recorded["gen_ai.response.id"], "msg_")
        assert recorded["http.response.status_code"] == 200
      end

      # The model chose to call a tool, so there is a tool span under a turn.
      assert [call | _rest] = named(spans, "execute_tool add")
      assert attributes(call)["gen_ai.tool.name"] == "add"

      turns = named(spans, "turn")
      turn_ids = MapSet.new(turns, &span(&1, :span_id))
      assert MapSet.member?(turn_ids, span(call, :parent_span_id))
      assert Enum.all?(turns, &(span(&1, :parent_span_id) == span(root, :span_id)))
    end

    test "records the prompt and the reply only when asked", %{client: client} do
      params = %{
        model: @model,
        max_tokens: 64,
        messages: [Message.user("Reply with exactly one word: pong")]
      }

      assert {:ok, _message} = Messages.create(client, params)
      [without_content] = named(collect([]), "chat " <> @model)

      refute Map.has_key?(attributes(without_content), "gen_ai.prompt")
      refute Map.has_key?(attributes(without_content), "gen_ai.completion")

      Application.put_env(:claudex, :trace_content, true)

      assert {:ok, _message} = Messages.create(client, params)
      [with_content] = named(collect([]), "chat " <> @model)
      recorded = attributes(with_content)

      assert recorded["gen_ai.prompt"] =~ "pong"
      assert %{"role" => "assistant"} = JSON.decode!(recorded["gen_ai.completion"])

      assert [%{"role" => "user", "parts" => _parts}] =
               JSON.decode!(recorded["gen_ai.input.messages"])
    end
  end

  describe "when the API refuses" do
    @unknown_model "claude-not-a-real-model"

    test "a refused request carries the API's own message", %{client: client} do
      params = %{model: @unknown_model, max_tokens: 16, messages: [Message.user("Hello")]}

      assert {:error, error} = Messages.create(client, params)
      assert error.status in 400..499

      [request] = named(collect([]), "chat " <> @unknown_model)

      assert {:status, :error, message} = span(request, :status)
      assert message =~ "model"
      assert attributes(request)["http.response.status_code"] == error.status
      refute Map.has_key?(attributes(request), "gen_ai.usage.input_tokens")
    end

    test "a refused streamed request is marked too", %{client: client} do
      params = %{model: @unknown_model, max_tokens: 16, messages: [Message.user("Hello")]}

      assert_raise Claudex.Error, fn ->
        client |> Messages.stream!(params) |> Enum.to_list()
      end

      [request] = named(collect([]), "chat " <> @unknown_model)

      assert {:status, :error, message} = span(request, :status)
      assert message != ""
    end

    test "a tool that refuses marks its own span and the run carries on", %{client: client} do
      params = %{
        model: @model,
        max_tokens: 512,
        system: @system <> " If a tool refuses, say the word cannot and stop.",
        tools: Calculator,
        messages: [Message.user("What is 6 divided by 0?")]
      }

      assert {:ok, turn} = ToolRunner.run(client, params)

      spans = collect([])

      assert [call | _rest] = named(spans, "execute_tool divide")
      assert {:status, :error, message} = span(call, :status)
      assert message =~ "cannot divide by zero"

      assert [root] = Enum.filter(spans, &(span(&1, :parent_span_id) == :undefined))
      assert attributes(root)["claudex.stop"] == "completed"
      assert turn.stop == :completed
    end
  end

  describe "requests that are not generations" do
    test "count_tokens carries a model and is still not one", %{client: client} do
      params = %{model: @model, messages: [Message.user("What is 12 plus 30?")]}

      assert {:ok, tokens} = Messages.count_tokens(client, params)
      assert tokens > 0

      [counting] = named(collect([]), "POST /v1/messages/count_tokens")
      recorded = attributes(counting)

      refute Map.has_key?(recorded, "gen_ai.operation.name")
      refute Map.has_key?(recorded, "gen_ai.request.model")
      assert recorded["http.response.status_code"] == 200
    end

    test "a models list is a plain request with no reply invented for it", %{client: client} do
      Application.put_env(:claudex, :trace_content, true)

      assert {:ok, _page} = Models.list(client, limit: 1)

      [listing] = named(collect([]), "GET /v1/models")
      recorded = attributes(listing)

      assert recorded["http.response.status_code"] == 200
      refute Map.has_key?(recorded, "gen_ai.system")
      refute Map.has_key?(recorded, "gen_ai.completion")
      refute Map.has_key?(recorded, "gen_ai.output.messages")
    end
  end

  defp named(spans, name), do: Enum.filter(spans, &(span(&1, :name) == name))

  defp attributes(recorded) do
    {:attributes, _count, _type, _dropped, map} = span(recorded, :attributes)

    map
  end

  defp collect(collected) do
    receive do
      {:span, recorded} -> collect([recorded | collected])
    after
      500 -> collected
    end
  end
end

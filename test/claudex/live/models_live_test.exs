defmodule Claudex.Live.ModelsTest do
  @moduledoc """
  End-to-end coverage of the Models API and token counting.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Messages, Model, Models, Page, Tool}

  defmodule CounterTools do
    @moduledoc false
    use Tool

    @doc "Adds two numbers."
    @tool true
    @spec add(number(), number()) :: number()
    def add(a, b), do: a + b
  end

  test "lists models and pages through them", %{client: client} do
    assert {:ok, %Page{} = page} =
             client |> Recorder.record_json("models_page") |> Models.list(limit: 3)

    assert length(page.data) <= 3
    assert [%Model{} = model | _rest] = page.data
    assert model.type == "model"
    assert %DateTime{} = model.created_at
    assert model.max_input_tokens > 0

    if page.has_more do
      assert {:ok, %Page{data: next}} = Models.list(client, limit: 3, after_id: page.last_id)
      assert next != []
      refute Enum.any?(next, &(&1.id == model.id))
    end
  end

  test "resolves an alias to a concrete model id", %{client: client} do
    assert {:ok, %Model{} = model} =
             client |> Recorder.record_json("model") |> Models.retrieve(@model)

    assert model.id =~ "claude-haiku-4-5"
    assert model.capabilities["thinking"]["supported"] == true
  end

  test "counts tokens, and counts more once tools are included", %{client: client} do
    messages = [%{role: "user", content: "What is 12 plus 30?"}]

    assert {:ok, without_tools} =
             Messages.count_tokens(client, %{model: @model, messages: messages})

    assert {:ok, with_tools} =
             Messages.count_tokens(client, %{
               model: @model,
               tools: CounterTools,
               messages: messages
             })

    assert without_tools > 0
    assert with_tools > without_tools
  end
end

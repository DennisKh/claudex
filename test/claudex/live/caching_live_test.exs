defmodule Claudex.Live.CachingTest do
  @moduledoc """
  End-to-end coverage of prompt caching: that `cache_control` reaches the API
  and that the cache token counts come back on `Claudex.Usage`.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.Messages

  # Claude Haiku 4.5 won't cache a prefix under 4096 tokens, and says so by
  # silently returning zero rather than erroring — hence a system prompt this
  # long, and the count_tokens assertion guarding it.
  @minimum_cacheable_tokens 4096

  setup %{client: client} do
    system = String.duplicate("The archivist catalogued every ledger before the winter. ", 900)

    {:ok, system: system, client: client}
  end

  test "reports cache writes and reads in usage", %{client: client, system: system} do
    params = %{
      model: @model,
      max_tokens: 16,
      system: [%{type: "text", text: system, cache_control: %{type: "ephemeral"}}],
      messages: [%{role: "user", content: "Reply with one word: ok"}]
    }

    {:ok, tokens} = Messages.count_tokens(client, Map.delete(params, :max_tokens))

    assert tokens > @minimum_cacheable_tokens,
           "system prompt is #{tokens} tokens, below the #{@minimum_cacheable_tokens} " <>
             "this model needs before anything caches"

    {:ok, first} = client |> Recorder.record_json("cached") |> Messages.create(params)

    written_or_read =
      (first.usage.cache_creation_input_tokens || 0) + (first.usage.cache_read_input_tokens || 0)

    assert written_or_read > 0, "expected the prefix to be cached, got #{inspect(first.usage)}"

    {:ok, second} = Messages.create(client, params)

    assert second.usage.cache_read_input_tokens > 0
  end
end

defmodule Claudex.UsageTest do
  use ExUnit.Case, async: true

  doctest Claudex.Usage

  alias Claudex.Usage

  test "merge/2 keeps fields the later object doesn't carry" do
    start = %Usage{input_tokens: 11, output_tokens: 1, service_tier: "standard"}
    delta = %Usage{output_tokens: 42}

    merged = Usage.merge(start, delta)

    assert merged.input_tokens == 11
    assert merged.output_tokens == 42
    assert merged.service_tier == "standard"
  end

  test "merge/2 handles either side being nil" do
    usage = %Usage{input_tokens: 3}

    assert Usage.merge(usage, nil) == usage
    assert Usage.merge(nil, usage) == usage
    assert Usage.merge(nil, nil) == nil
  end

  describe "cached?/1" do
    test "a read or a write means the cache did something" do
      assert Usage.cached?(%Usage{cache_read_input_tokens: 2048})
      assert Usage.cached?(%Usage{cache_creation_input_tokens: 2048})
    end

    test "zero on both is a prefix the API declined to cache" do
      refute Usage.cached?(%Usage{cache_creation_input_tokens: 0, cache_read_input_tokens: 0})
    end

    test "an endpoint that reports no cache counters at all is not cached" do
      refute Usage.cached?(%Usage{input_tokens: 15, output_tokens: 5})
    end
  end
end

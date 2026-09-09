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
end

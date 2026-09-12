defmodule Claudex.ModelTest do
  use ExUnit.Case, async: true

  alias Claudex.Model

  # The shape the Models API returns: every node carries its own flag, and
  # nested ones sit beside it.
  @model %Model{
    id: "claude-sonnet-5",
    capabilities: %{
      "image_input" => %{"supported" => true},
      "thinking" => %{
        "supported" => true,
        "types" => %{
          "adaptive" => %{"supported" => true},
          "enabled" => %{"supported" => false}
        }
      }
    }
  }

  test "supports?/2 reads the flag at the end of the path" do
    assert Model.supports?(@model, ["image_input"])
    assert Model.supports?(@model, ["thinking"])
    assert Model.supports?(@model, ["thinking", "types", "adaptive"])
  end

  test "supports?/2 is false for a capability the model turns down" do
    refute Model.supports?(@model, ["thinking", "types", "enabled"])
  end

  test "supports?/2 is false for a path the model doesn't have" do
    refute Model.supports?(@model, ["invented_2027"])
    refute Model.supports?(@model, ["thinking", "types", "invented_2027"])
    refute Model.supports?(@model, ["image_input", "deeper", "still"])
  end

  test "supports?/2 takes a single capability as a string" do
    assert Model.supports?(@model, "image_input")
    refute Model.supports?(@model, "invented_2027")
  end

  test "supports?/2 is false when the model has no capabilities at all" do
    refute Model.supports?(%Model{id: "old"}, ["image_input"])
  end
end

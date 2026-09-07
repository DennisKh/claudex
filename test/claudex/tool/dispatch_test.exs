defmodule Claudex.Tool.DispatchTest do
  use ExUnit.Case, async: true

  alias Claudex.Tool.Dispatch

  defmodule Target do
    def add(a, b), do: a + b
    def greet(name, greeting \\ "hi"), do: "#{greeting}, #{name}"
    def boom, do: raise("kaboom")
    def yeet, do: throw(:nope)
    def bail, do: exit(:shutdown)
  end

  defp entry(name, function, params), do: %{name: name, function: function, params: params}

  test "calls the matching function with args resolved by name, not JSON key order" do
    entries = [entry("add", :add, [{"a", false}, {"b", false}])]

    assert Dispatch.call(Target, entries, "add", %{"b" => 2, "a" => 1}) == {:ok, 3}
  end

  test "returns an error for an unregistered tool name" do
    assert Dispatch.call(Target, [], "missing", %{}) == {:error, {:unknown_tool, "missing"}}
  end

  test "returns an error when a required argument is missing" do
    entries = [entry("add", :add, [{"a", false}, {"b", false}])]

    assert Dispatch.call(Target, entries, "add", %{"a" => 1}) ==
             {:error, {:missing_args, ["b"]}}
  end

  test "uses the function's own default when a trailing optional argument is omitted" do
    entries = [entry("greet", :greet, [{"name", false}, {"greeting", true}])]

    assert Dispatch.call(Target, entries, "greet", %{"name" => "Ada"}) == {:ok, "hi, Ada"}
  end

  test "uses the given value when an optional argument is present" do
    entries = [entry("greet", :greet, [{"name", false}, {"greeting", true}])]

    assert Dispatch.call(Target, entries, "greet", %{"name" => "Ada", "greeting" => "yo"}) ==
             {:ok, "yo, Ada"}
  end

  test "wraps a raised exception as a tool_raised error instead of crashing" do
    entries = [entry("boom", :boom, [])]

    assert {:error, {:tool_raised, message}} = Dispatch.call(Target, entries, "boom", %{})

    # The type is in the message so a bug reads differently from a refusal.
    assert message == "RuntimeError: kaboom"
  end

  test "wraps a thrown value as a tool_raised error instead of crashing" do
    entries = [entry("yeet", :yeet, [])]

    assert {:error, {:tool_raised, message}} = Dispatch.call(Target, entries, "yeet", %{})
    assert message =~ "threw :nope"
  end

  test "wraps an exit as a tool_raised error instead of taking the caller down" do
    entries = [entry("bail", :bail, [])]

    assert {:error, {:tool_raised, message}} = Dispatch.call(Target, entries, "bail", %{})
    assert message =~ "exited: :shutdown"
  end
end

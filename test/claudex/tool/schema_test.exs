defmodule Claudex.Tool.SchemaTest do
  use ExUnit.Case, async: true

  alias Claudex.TestSupport.Schemas.Ticket
  alias Claudex.Tool.{Schema, SchemaError}

  doctest Claudex.Tool.Schema

  defp var(name), do: Macro.var(name, nil)
  defp defaulted(name, default), do: {:\\, [], [var(name), default]}

  defp spec(name, arg_types) do
    {:spec, {:"::", [], [{name, [], arg_types}, quote(do: term())]}, {__MODULE__, {1, 1}}}
  end

  defp build(name, args, specs), do: Schema.build(name, args, specs, __ENV__)

  test "maps a scalar @spec to typed properties and marks params without defaults required" do
    args = [var(:a), var(:b)]
    specs = [spec(:add, [quote(do: integer()), quote(do: float())])]

    built = build(:add, args, specs)

    assert built.properties == %{"a" => %{type: "integer"}, "b" => %{type: "number"}}
    assert built.params == [{"a", false}, {"b", false}]
  end

  test "params with a default value are not required" do
    args = [var(:a), defaulted(:b, 0)]
    specs = [spec(:add, [quote(do: number()), quote(do: number())])]

    built = build(:add, args, specs)

    assert built.params == [{"a", false}, {"b", true}]
  end

  test "falls back to an unconstrained property when there's no matching @spec" do
    built = build(:mystery, [var(:x)], [])

    assert built.properties == %{"x" => %{}}
  end

  test "ignores a @spec for a different function or arity" do
    specs = [spec(:other, [quote(do: integer())]), spec(:add, [quote(do: integer())])]

    built = build(:add, [var(:a), var(:b)], specs)

    assert built.properties == %{"a" => %{}, "b" => %{}}
  end

  test "maps non_neg_integer and pos_integer with a minimum" do
    specs = [spec(:f, [quote(do: non_neg_integer()), quote(do: pos_integer())])]

    built = build(:f, [var(:a), var(:b)], specs)

    assert built.properties["a"] == %{type: "integer", minimum: 0}
    assert built.properties["b"] == %{type: "integer", minimum: 1}
  end

  test "maps String.t() and other Module.t() remote types" do
    specs = [spec(:f, [quote(do: String.t()), quote(do: DateTime.t()), quote(do: Date.t())])]

    built = build(:f, [var(:a), var(:b), var(:c)], specs)

    assert built.properties["a"] == %{type: "string"}
    assert built.properties["b"] == %{type: "string", format: "date-time"}
    assert built.properties["c"] == %{type: "string", format: "date"}
  end

  test "raises for a Mod.t() that isn't a loaded struct or Ecto schema" do
    specs = [spec(:f, [quote(do: MyApp.DoesNotExist.t())])]

    assert_raise SchemaError, ~r/isn't a loaded struct or an Ecto schema/, fn ->
      build(:f, [var(:a)], specs)
    end
  end

  test "raises for a typespec construct Claudex doesn't map, pointing at args_schema" do
    specs = [spec(:f, [quote(do: pid())])]

    assert_raise SchemaError,
                 ~r/can't build a JSON schema for type `pid\(\)`.*args_schema: in the @tool/s,
                 fn -> build(:f, [var(:a)], specs) end
  end

  test "maps a non-empty list, however the typespec spells it" do
    specs = [
      spec(:f, [quote(do: nonempty_list(String.t())), quote(do: [String.t(), ...])])
    ]

    built = build(:f, [var(:a), var(:b)], specs)

    array = %{type: "array", items: %{type: "string"}, minItems: 1}

    assert built.properties == %{"a" => array, "b" => array}
  end

  test "expands a struct's Mod.t() into a nested object, resolving an aliased reference" do
    # Ticket is aliased at the top of this file — Ticket.t() in the spec
    # AST below is {:__aliases__, _, [:Ticket]}, not the full module path.
    # This is the exact shape that broke before env-based alias resolution
    # was added: Module.concat([:Ticket]) alone resolves to the wrong,
    # nonexistent module.
    specs = [spec(:f, [quote(do: Ticket.t())])]

    built = build(:f, [var(:ticket)], specs)

    assert %{type: "object", properties: properties, required: required} =
             built.properties["ticket"]

    assert Map.keys(properties) |> Enum.sort() == ["address", "id", "status", "subject"]
    assert Enum.sort(required) == ["id", "status", "subject"]
  end

  test "maps list(t) and the [t] shorthand to array schemas" do
    specs = [spec(:f, [quote(do: list(integer())), quote(do: [String.t()])])]

    built = build(:f, [var(:a), var(:b)], specs)

    assert built.properties["a"] == %{type: "array", items: %{type: "integer"}}
    assert built.properties["b"] == %{type: "array", items: %{type: "string"}}
  end

  test "collapses a union of same-type literals into an enum" do
    specs = [spec(:f, [quote(do: :celsius | :fahrenheit)])]

    built = build(:f, [var(:unit)], specs)

    assert built.properties["unit"] == %{type: "string", enum: ["celsius", "fahrenheit"]}
  end

  test "falls back to anyOf for a union of mixed member kinds" do
    specs = [spec(:f, [quote(do: float() | 0)])]

    built = build(:f, [var(:b)], specs)

    assert built.properties["b"] == %{anyOf: [%{type: "number"}, %{const: 0}]}
  end

  test "maps a literal nil in a union to a null branch" do
    specs = [spec(:f, [quote(do: String.t() | nil)])]

    built = build(:f, [var(:a)], specs)

    assert built.properties["a"] == %{anyOf: [%{type: "string"}, %{type: "null"}]}
  end

  test "maps boolean, atom, and map types" do
    specs = [spec(:f, [quote(do: boolean()), quote(do: atom()), quote(do: map())])]

    built = build(:f, [var(:a), var(:b), var(:c)], specs)

    assert built.properties["a"] == %{type: "boolean"}
    assert built.properties["b"] == %{type: "string"}
    assert built.properties["c"] == %{type: "object"}
  end
end

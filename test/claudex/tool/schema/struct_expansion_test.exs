defmodule Claudex.Tool.Schema.StructExpansionTest do
  use ExUnit.Case, async: true

  alias Claudex.TestSupport.Schemas.{EctoMailbox, EctoTicket, Node, Reflected, Ticket, Untyped}
  alias Claudex.Tool.Schema.StructExpansion
  alias Claudex.Tool.SchemaError

  defp ctx, do: %{visited: [], env: __ENV__, current_module: __MODULE__}

  describe "plain structs" do
    test "expands a typed struct's fields, recursing into a nested struct type" do
      {:ok, schema} = StructExpansion.expand(Ticket, ctx())

      assert schema.type == "object"
      assert schema.properties["id"] == %{type: "integer"}
      assert schema.properties["subject"] == %{type: "string"}
      assert schema.properties["status"] == %{type: "string", enum: ["open", "closed"]}

      assert %{anyOf: [address_object, %{type: "null"}]} = schema.properties["address"]
      assert address_object.properties["city"] == %{type: "string"}
    end

    test "requires every field, a nil-able one included" do
      {:ok, schema} = StructExpansion.expand(Ticket, ctx())

      assert Enum.sort(schema.required) == ["address", "id", "status", "subject"]
      assert %{anyOf: [_address, %{type: "null"}]} = schema.properties["address"]
    end

    test "breaks a self-referential struct's cycle instead of recursing forever" do
      {:ok, schema} = StructExpansion.expand(Node, ctx())

      assert schema.properties["value"] == %{type: "integer"}
      assert schema.properties["next"] == %{anyOf: [%{}, %{type: "null"}]}
    end

    test "falls back to unconstrained-but-named properties for a struct with no @type t" do
      {:ok, schema} = StructExpansion.expand(Untyped, ctx())

      assert schema == %{
               type: "object",
               properties: %{"a" => %{}, "b" => %{}},
               required: ["a", "b"],
               additionalProperties: false
             }
    end

    test "disallows additional properties on nested objects, not just the top level" do
      {:ok, schema} = StructExpansion.expand(Ticket, ctx())

      assert schema.additionalProperties == false

      assert %{anyOf: [address_object, %{type: "null"}]} = schema.properties["address"]
      assert address_object.additionalProperties == false
    end

    test "returns :unsupported for a module that isn't loaded" do
      assert StructExpansion.expand(NoSuchModuleAtAll, ctx()) == :unsupported
    end

    test "returns :cycle (not infinite recursion) when the module is already in visited" do
      already_visiting = %{ctx() | visited: [Ticket]}

      assert StructExpansion.expand(Ticket, already_visiting) == :cycle
    end
  end

  describe "Ecto schemas" do
    setup do
      {:ok, schema} = StructExpansion.expand(EctoTicket, ctx())
      {:ok, schema: schema}
    end

    test "includes scalar fields and the belongs_to foreign key, typed correctly", %{
      schema: schema
    } do
      assert schema.properties["subject"] == nullable(%{type: "string"})
      assert schema.properties["tags"] == nullable(%{type: "array", items: %{type: "string"}})
      assert schema.properties["price"] == nullable(%{type: "string"})
      assert schema.properties["opened_at"] == nullable(%{type: "string", format: "date-time"})
      assert schema.properties["assignee_id"] == nullable(%{type: "integer"})
    end

    test "maps an Ecto.Enum field to a string enum of its dump values", %{schema: schema} do
      assert schema.properties["status"] == nullable(%{type: "string", enum: ["open", "closed"]})
    end

    test "excludes has_many/belongs_to association fields themselves", %{schema: schema} do
      refute Map.has_key?(schema.properties, "comments")
      refute Map.has_key?(schema.properties, "assignee")
    end

    test "expands an embeds_one field into a nested object", %{schema: schema} do
      assert %{anyOf: [%{type: "object", properties: address_properties}, %{type: "null"}]} =
               schema.properties["address"]

      assert address_properties["city"] == nullable(%{type: "string"})
      assert address_properties["zip"] == nullable(%{type: "string"})
    end

    test "requires every field, each one nullable, since Ecto doesn't expose NOT NULL", %{
      schema: schema
    } do
      assert Enum.sort(schema.required) == schema.properties |> Map.keys() |> Enum.sort()
      assert Enum.all?(Map.values(schema.properties), &match?(%{anyOf: [_, %{type: "null"}]}, &1))
    end

    test "keeps an embeds_many list required and not null, since Ecto rejects a nil one" do
      {:ok, schema} = StructExpansion.expand(EctoMailbox, ctx())

      assert "addresses" in schema.required
      assert %{type: "array", items: %{type: "object"}} = schema.properties["addresses"]
      assert schema.properties["owner"] == nullable(%{type: "string"})
    end

    test "disallows additional properties on the schema and its embeds", %{schema: schema} do
      assert schema.additionalProperties == false

      assert %{anyOf: [%{additionalProperties: false}, %{type: "null"}]} =
               schema.properties["address"]
    end
  end

  describe "an Ecto field Claudex can't map" do
    defp hatched, do: Map.put(ctx(), :escape_hatch, "Do this instead")

    test "a custom type with no type/0 callback" do
      assert_raise SchemaError, ~r/doesn't implement Ecto.Type's type\/0.*Do this instead/s, fn ->
        StructExpansion.expand(Reflected.CustomType, hatched())
      end
    end

    test "a field type Claudex doesn't recognise" do
      assert_raise SchemaError, ~r/`\{:parameterized.*Do this instead/s, fn ->
        StructExpansion.expand(Reflected.UnknownType, hatched())
      end
    end

    test "an embed that isn't a schema" do
      assert_raise SchemaError,
                   ~r/embedded schema.*isn't a loaded Ecto schema. Do this instead/s,
                   fn ->
                     StructExpansion.expand(Reflected.BadEmbed, hatched())
                   end
    end

    test "falls back to the @tool advice when the context names none" do
      assert_raise SchemaError, ~r/args_schema: in the @tool options/, fn ->
        StructExpansion.expand(Reflected.CustomType, ctx())
      end
    end
  end

  defp nullable(schema), do: %{anyOf: [schema, %{type: "null"}]}
end

defmodule Claudex.Tool.Schema.StructExpansionTest do
  use ExUnit.Case, async: true

  alias Claudex.TestSupport.Schemas.{EctoTicket, Node, Ticket, Untyped}
  alias Claudex.Tool.Schema.StructExpansion

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

    test "marks a nil-able field optional and everything else required" do
      {:ok, schema} = StructExpansion.expand(Ticket, ctx())

      assert Enum.sort(schema.required) == ["id", "status", "subject"]
      refute "address" in schema.required
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
               required: [],
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
      assert schema.properties["subject"] == %{type: "string"}
      assert schema.properties["tags"] == %{type: "array", items: %{type: "string"}}
      assert schema.properties["price"] == %{type: "string"}
      assert schema.properties["opened_at"] == %{type: "string", format: "date-time"}
      assert schema.properties["assignee_id"] == %{type: "integer"}
    end

    test "maps an Ecto.Enum field to a string enum of its dump values", %{schema: schema} do
      assert schema.properties["status"] == %{type: "string", enum: ["open", "closed"]}
    end

    test "excludes has_many/belongs_to association fields themselves", %{schema: schema} do
      refute Map.has_key?(schema.properties, "comments")
      refute Map.has_key?(schema.properties, "assignee")
    end

    test "expands an embeds_one field into a nested object", %{schema: schema} do
      assert %{type: "object", properties: address_properties} = schema.properties["address"]
      assert address_properties["city"] == %{type: "string"}
      assert address_properties["zip"] == %{type: "string"}
    end

    test "required is always empty — Ecto doesn't expose NOT NULL info", %{schema: schema} do
      assert schema.required == []
    end

    test "disallows additional properties on the schema and its embeds", %{schema: schema} do
      assert schema.additionalProperties == false
      assert schema.properties["address"].additionalProperties == false
    end
  end
end

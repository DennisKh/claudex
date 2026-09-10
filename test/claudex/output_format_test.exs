defmodule Claudex.OutputFormatTest do
  use ExUnit.Case, async: true

  alias Claudex.OutputFormat
  alias Claudex.TestSupport.{Ticket, Tupled, Vague}
  alias Claudex.Tool.SchemaError

  defp schema, do: OutputFormat.json_schema(Ticket).schema

  defp property(name), do: schema().properties[name]

  test "wraps the schema in the format the API takes" do
    assert %{type: "json_schema", schema: %{type: "object"}} = OutputFormat.json_schema(Ticket)
  end

  test "closes every object, however deep" do
    assert schema().additionalProperties == false
    assert property("reporter").additionalProperties == false
    assert property("metadata").additionalProperties == false
  end

  test "carries a constraint the API rejects in the description instead" do
    # non_neg_integer() implies minimum: 0, which the API refuses for integers.
    assert property("id") == %{type: "integer", description: "{minimum: 0}"}
  end

  test "keeps minItems, which the API takes for 0 and 1" do
    assert property("tags") == %{type: "array", items: %{type: "string"}, minItems: 1}
  end

  test "keeps an enum and a supported string format" do
    assert property("priority") == %{type: "string", enum: ["low", "high"]}
    assert %{anyOf: [%{type: "string", format: "date"}, _null]} = property("due")
  end

  test "an optional field is a union with null, and stays out of required" do
    assert %{anyOf: [%{type: "string"}, %{type: "null"}]} =
             property("reporter").properties["email"]

    assert property("reporter").required == ["name"]
  end

  test "a field with no describable type raises, naming the field" do
    assert_raise SchemaError, ~r/`notes` has no type the API can be told about/, fn ->
      OutputFormat.json_schema(Vague)
    end
  end

  test "a field Claudex can't map says what to do about an output format" do
    assert_raise SchemaError,
                 ~r/type `\{String.t\(\), integer\(\)\}`.*pass output_config.format yourself/s,
                 fn -> OutputFormat.json_schema(Tupled) end
  end

  test "a struct with no readable types says so, rather than blaming its fields" do
    assert_raise SchemaError,
                 ~r/can't read `Claudex.TestSupport.Bare`'s `@type t`.*strip_beams/s,
                 fn ->
                   OutputFormat.json_schema(Claudex.TestSupport.Bare)
                 end
  end

  test "a module that isn't a struct raises" do
    assert_raise SchemaError, ~r/can't build an output format for `Enum`/, fn ->
      OutputFormat.json_schema(Enum)
    end
  end
end

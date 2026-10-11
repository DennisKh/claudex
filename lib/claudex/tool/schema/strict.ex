defmodule Claudex.Tool.Schema.Strict do
  @moduledoc """
  Fits a JSON schema to the subset the API takes for structured outputs and
  strict tools.

  Every object is closed with `additionalProperties: false`, and whatever the
  subset rejects, such as the `minimum: 0` that a `non_neg_integer()` implies,
  moves into that property's description, where the model still reads it.
  """

  alias Claudex.Tool.SchemaError

  @string_formats ~w(date-time time date duration email hostname uri ipv4 ipv6 uuid)
  @carried [:enum, :const, :description, :title]

  @doc """
  Fits `schema`, an atom-keyed JSON schema, to the strict subset.

  Raises `Claudex.Tool.SchemaError` when a property has no type the subset can
  express, such as the empty schema `any()` becomes. `reason` ends that
  message, after the path to the property.
  """
  @spec fit(map(), String.t()) :: map()
  def fit(schema, reason), do: strict(schema, [], reason)

  defp strict(schema, path, reason) do
    {kept, used} = supported(schema, path, reason)
    kept = Map.merge(kept, Map.take(schema, @carried))

    if kept == %{}, do: raise(SchemaError, message: unexpressible(path, reason))

    describe(kept, Map.drop(schema, used ++ @carried))
  end

  defp supported(%{anyOf: variants}, path, reason) do
    {%{anyOf: Enum.map(variants, &strict(&1, path, reason))}, [:anyOf]}
  end

  defp supported(%{type: "object"} = schema, path, reason) do
    properties =
      for {name, property} <- Map.get(schema, :properties, %{}),
          into: %{},
          do: {name, strict(property, path ++ [name], reason)}

    object = %{type: "object", properties: properties, additionalProperties: false}

    object =
      case schema do
        %{required: required} -> Map.put(object, :required, required)
        _no_required -> object
      end

    used =
      case schema do
        %{additionalProperties: value} when is_map(value) -> [:type, :properties, :required]
        _closed -> [:type, :properties, :additionalProperties, :required]
      end

    {object, used}
  end

  defp supported(%{type: "array"} = schema, path, reason) do
    array =
      case schema do
        %{items: items} -> %{type: "array", items: strict(items, path, reason)}
        _no_items -> %{type: "array"}
      end

    case schema do
      %{minItems: count} when count in [0, 1] ->
        {Map.put(array, :minItems, count), [:type, :items, :minItems]}

      _other_count ->
        {array, [:type, :items]}
    end
  end

  defp supported(%{type: "string"} = schema, _path, _reason) do
    case schema do
      %{format: format} when format in @string_formats ->
        {%{type: "string", format: format}, [:type, :format]}

      _unsupported_format ->
        {%{type: "string"}, [:type]}
    end
  end

  defp supported(%{type: type}, _path, _reason), do: {%{type: type}, [:type]}

  defp supported(_schema, _path, _reason), do: {%{}, []}

  defp describe(kept, unsupported) when unsupported == %{}, do: kept

  defp describe(kept, unsupported) do
    hints = Enum.map_join(unsupported, ", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)

    Map.update(kept, :description, "{#{hints}}", &(&1 <> "\n\n{#{hints}}"))
  end

  defp unexpressible([], _reason), do: "this struct has no type the API can be told about"

  defp unexpressible(path, reason) do
    "`#{Enum.join(path, ".")}` has no type the API can be told about. " <> reason
  end
end

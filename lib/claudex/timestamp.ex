defmodule Claudex.Timestamp do
  @moduledoc false

  @doc """
  Decodes an RFC 3339 timestamp from the API.

  Returns nil for a missing or unparseable value rather than failing the whole
  response — some timestamps are documented as absent, and the API may use an
  epoch value when a date is unknown.
  """
  @spec decode(term()) :: DateTime.t() | nil
  def decode(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  def decode(_value), do: nil
end

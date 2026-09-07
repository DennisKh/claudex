defmodule Claudex.JSONLTest do
  use ExUnit.Case, async: true

  alias Claudex.JSONL

  defp decode_all(chunks) do
    {lines, decoder} =
      Enum.reduce(chunks, {[], JSONL.new()}, fn chunk, {lines, decoder} ->
        {new_lines, decoder} = JSONL.decode(decoder, chunk)
        {lines ++ new_lines, decoder}
      end)

    {trailing, _decoder} = JSONL.flush(decoder)
    lines ++ trailing
  end

  test "decode/2 returns complete lines and holds the partial one" do
    {lines, decoder} = JSONL.decode(JSONL.new(), ~s|{"a":1}\n{"b":|)

    assert lines == [~s|{"a":1}|]
    assert decoder.buffer == ~s|{"b":|
  end

  test "decode/2 completes a line once the rest arrives" do
    {[], decoder} = JSONL.decode(JSONL.new(), ~s|{"a":|)
    {lines, _decoder} = JSONL.decode(decoder, "1}\n")

    assert lines == [~s|{"a":1}|]
  end

  test "decode/2 drops blank lines" do
    {lines, _decoder} = JSONL.decode(JSONL.new(), "{}\n\n\n{}\n")

    assert lines == ["{}", "{}"]
  end

  test "flush/1 returns a final line with no trailing newline" do
    {[], decoder} = JSONL.decode(JSONL.new(), ~s|{"a":1}|)

    assert {[~s|{"a":1}|], decoder} = JSONL.flush(decoder)
    assert decoder.buffer == ""
  end

  test "flush/1 returns nothing for an empty or blank buffer" do
    assert {[], _decoder} = JSONL.flush(JSONL.new())

    {["{}"], decoder} = JSONL.decode(JSONL.new(), "{}\n   ")
    assert {[], _decoder} = JSONL.flush(decoder)
  end

  test "decode/2 gives the same lines however the bytes are split" do
    document =
      ~s|{"custom_id":"a","result":{"type":"succeeded"}}\n| <>
        ~s|{"custom_id":"b","result":{"type":"expired"}}\n|

    expected = decode_all([document])

    assert length(expected) == 2
    assert decode_all(for <<byte <- document>>, do: <<byte>>) == expected
    assert decode_all(chunk_every(document, 7)) == expected
  end

  test "decode/2 keeps a line that contains an escaped newline intact" do
    {lines, _decoder} = JSONL.decode(JSONL.new(), ~s|{"text":"a\\nb"}\n|)

    assert lines == [~s|{"text":"a\\nb"}|]
  end

  defp chunk_every(binary, size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end
end

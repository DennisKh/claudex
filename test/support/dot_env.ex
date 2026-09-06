defmodule Claudex.TestSupport.DotEnv do
  @moduledoc """
  Loads a dotenv-style file (`KEY=VALUE` per line) into the process
  environment. Used by `test/test_helper.exs` to read `.env.test` before
  the live API tests run — see `test/claudex/live/`.

  A variable already set in the environment is left alone, so a real
  `ANTHROPIC_API_KEY` exported by CI or your shell always wins over the file.
  """

  @spec load(Path.t()) :: :ok
  def load(path) do
    if File.exists?(path) do
      path |> File.read!() |> String.split("\n") |> Enum.each(&put_line/1)
    end

    :ok
  end

  defp put_line(line) do
    case parse(line) do
      {key, value} -> put_new_env(key, value)
      :skip -> :ok
    end
  end

  defp put_new_env(key, value) do
    if is_nil(System.get_env(key)), do: System.put_env(key, value)
  end

  defp parse(line) do
    case String.trim(line) do
      "" -> :skip
      "#" <> _comment -> :skip
      trimmed -> split(trimmed)
    end
  end

  defp split(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> {String.trim(key), unquote_value(String.trim(value))}
      _other -> :skip
    end
  end

  defp unquote_value(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_value(value), do: value
end

defmodule Claudex.Tool.Dispatch do
  @moduledoc """
  Calls a registered tool function with a decoded `tool_use` input map.

  Arguments are matched to the function's parameters by name, not by the
  order keys happen to come back from JSON decoding — Elixir maps don't
  guarantee that order matches the function's declared parameter order.
  """

  @typedoc "One dispatchable tool: its wire name, the function it calls, and that function's parameters in order."
  @type entry :: %{name: String.t(), function: atom(), params: [Claudex.Tool.Schema.param()]}

  @type error ::
          {:unknown_tool, String.t()}
          | {:missing_args, [String.t()]}
          | {:tool_refused, String.t()}
          | {:tool_raised, String.t()}

  @doc """
  Looks up `name` in `entries` and calls the matching function on `module`
  with `args` (typically a `Claudex.ContentBlock.ToolUse.input` map).

  A trailing optional parameter left out of `args` gets the function's own
  default. An optional parameter left out while a later one is present
  can't fall back to its default — Elixir can only skip defaults from the
  end of the argument list — so it's called with `nil` instead; keep
  optional tool parameters to the ones you're fine skipping that way.
  """
  @spec call(module(), [entry()], String.t(), map()) :: {:ok, term()} | {:error, error()}
  def call(module, entries, name, args) do
    case Enum.find(entries, &(&1.name == name)) do
      nil -> {:error, {:unknown_tool, name}}
      entry -> call_entry(module, entry, args)
    end
  end

  defp call_entry(module, entry, args) do
    case ordered_args(entry.params, args) do
      {:ok, ordered} -> invoke(module, entry.function, ordered)
      {:error, _reason} = error -> error
    end
  end

  defp ordered_args(params, args) do
    resolved =
      Enum.map(params, fn {name, has_default} ->
        {name, has_default, Map.fetch(args, Atom.to_string(name))}
      end)

    case missing_required(resolved) do
      [] -> {:ok, values(resolved)}
      missing -> {:error, {:missing_args, missing}}
    end
  end

  defp missing_required(resolved) do
    resolved
    |> Enum.filter(fn {_name, has_default, fetch} -> not has_default and fetch == :error end)
    |> Enum.map(fn {name, _has_default, _fetch} -> Atom.to_string(name) end)
  end

  defp values(resolved) do
    resolved
    |> Enum.reverse()
    |> drop_trailing_missing()
    |> Enum.reverse()
    |> Enum.map(fn {_name, _has_default, fetch} -> unwrap(fetch) end)
  end

  defp drop_trailing_missing([{_name, true, :error} | rest]), do: drop_trailing_missing(rest)
  defp drop_trailing_missing(resolved), do: resolved

  defp unwrap({:ok, value}), do: value
  defp unwrap(:error), do: nil

  # A tool is someone else's code, so a failure in it comes back as an error
  # tuple the caller can turn into an is_error tool_result — never a crash
  # of the process running the loop. `catch` covers the throws and exits
  # `rescue` alone would let through.
  defp invoke(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    # A tool refusing on purpose is not the same as a tool with a bug in it,
    # and the caller needs to tell them apart: one is a message for the model,
    # the other is something to fix and to log.
    exception in Claudex.Tool.Error ->
      {:error, {:tool_refused, Exception.message(exception)}}

    exception ->
      # The type is part of the message: a KeyError from a bug in a tool has to
      # be distinguishable from a considered refusal when Claude reads it back.
      {:error,
       {:tool_raised, "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"}}
  catch
    :throw, value -> {:error, {:tool_raised, "tool threw #{inspect(value)}"}}
    :exit, reason -> {:error, {:tool_raised, "tool exited: #{inspect(reason)}"}}
  end
end

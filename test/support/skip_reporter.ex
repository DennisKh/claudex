defmodule Claudex.TestSupport.SkipReporter do
  @moduledoc false

  use GenServer

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {:skipped, reason}} = test}, skipped) do
    IO.puts(:stderr, "SKIPPED #{inspect(test.module)} #{inspect(test.name)} — #{reason}")

    {:noreply, [test | skipped]}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end

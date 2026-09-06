defmodule Claudex.TestSupport.LiveCase do
  @moduledoc """
  Shared setup for the end-to-end tests in `test/claudex/live/`.

  Every case using this is tagged `:live`, so it's excluded from `mix test` and
  runs under `mix test.live`. Without a real `ANTHROPIC_API_KEY` in the
  environment, the whole case skips with a reason instead of failing.

  The `client` in context is a plain `Claudex.Client`; wrap it with
  `Claudex.TestSupport.Recorder` in a test that should capture its payload.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Claudex.TestSupport.{Fixtures, Recorder}

      # From `:claudex_test`, not from the environment: test_helper.exs stashes
      # it there before any test file loads, because a test that deletes
      # ANTHROPIC_API_KEY can run while this module is still being compiled.
      #
      # Read through a function so the compiler doesn't see a config lookup in
      # a module body. Its warning is about a value going stale between build
      # and boot, which can't happen here: this file is recompiled on every
      # run, moments after test_helper.exs sets the value.
      @api_key unquote(__MODULE__).configured_api_key()

      @moduletag :live
      @moduletag timeout: 60_000
      @moduletag skip: unquote(__MODULE__).skip_reason(@api_key)

      @model "claude-haiku-4-5"

      setup do
        {:ok, client: Claudex.new(api_key: @api_key)}
      end
    end
  end

  @doc false
  @spec configured_api_key() :: String.t() | nil
  def configured_api_key, do: Application.get_env(:claudex_test, :api_key)

  @doc false
  @spec skip_reason(String.t() | nil) :: String.t() | nil
  def skip_reason(api_key) when api_key in [nil, ""] do
    "no ANTHROPIC_API_KEY in the environment"
  end

  def skip_reason(_api_key), do: nil
end

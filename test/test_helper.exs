Claudex.TestSupport.DotEnv.load(Path.expand("../.env.test", __DIR__))

# Stash the key somewhere no test writes to. `mix test` starts async tests
# while other test files are still loading, so a test that deletes
# ANTHROPIC_API_KEY (client_test.exs does, to cover the missing-key path) can
# run while test/claudex/live/*.exs is being compiled — and those modules read
# the key at compile time to decide whether to skip. That race silently skipped
# live tests while the suite still reported success.
Application.put_env(:claudex_test, :api_key, System.get_env("ANTHROPIC_API_KEY"))

# SkipReporter names any test ExUnit skips. The default formatter reports only
# a count, which is how a load-order race silently skipped live tests while the
# suite still read as passing.
ExUnit.start(
  exclude: [:live],
  formatters: [ExUnit.CLIFormatter, Claudex.TestSupport.SkipReporter]
)

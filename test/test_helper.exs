Application.put_env(:claudex_test, :api_key, System.get_env("ANTHROPIC_API_KEY"))

# SkipReporter names any test ExUnit skips. The default formatter reports only
# a count, which is how a load-order race silently skipped live tests while the
# suite still read as passing.
ExUnit.start(
  exclude: [:live],
  formatters: [ExUnit.CLIFormatter, Claudex.TestSupport.SkipReporter]
)

import Config

if config_env() == :test do
  # A span reaches the test process instead of an exporter, so a test can
  # assert on what was recorded. Nothing here ships: `config/` is not in the
  # package's file list.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end

import Config

config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none

# Tracing is off unless an app asks for it; the tests ask.
config :claudex, tracing: true

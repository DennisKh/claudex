import Config

config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none

config :claudex, tracing: true

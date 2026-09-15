import Config

if config_env() == :test do
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end

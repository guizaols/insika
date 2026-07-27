# frozen_string_literal: true

require "async"
require_relative "telemetry/pricing"
require_relative "telemetry/recorder"

module Insika
  # OPT-IN observability (Phase 6): OTEL mounted at the edge, core untouched. Rides
  # the Event Stream — the Recorder consumes the events and emits spans and metrics.
  # Off (the default) -> `setup` returns nil and nothing is loaded or instrumented
  # (parity, zero overhead). The OTEL gems are only REQUIRED lazily in `setup`
  # (enabled), never at core load — like ruby_llm in the Executor.
  #
  # Turn on: `INSIKA_OTEL=1` OR the standard OTEL envs
  # (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_EXPORTER`). The destination/protocol
  # follows the OTEL SDK's default config (env) — SigNoz/Tempo/Jaeger/Collector. The
  # OTEL_* keys are the OpenTelemetry SDK's own env and stay verbatim; only our opt-in
  # toggle is renamed (INSIKA_OTEL, with the HARNESS_OTEL alias still read).
  #
  # Metrics (item 16 / P4) ride the same switch and the SAME standard env: the SDK
  # registers a periodic metric reader when the OTLP metrics exporter is loadable,
  # and `OTEL_METRICS_EXPORTER=none` turns metrics off while traces stay on. No
  # Insika-specific toggle is invented for it.
  module Telemetry
    module_function

    def enabled?(env = ENV)
      truthy(Insika::EnvSchema.read("INSIKA_OTEL", env)) ||
        present?(env["OTEL_EXPORTER_OTLP_ENDPOINT"]) ||
        present?(env["OTEL_TRACES_EXPORTER"])
    end

    # -> Recorder wired to the real OTEL | nil (disabled). Idempotent per process
    # (configures the SDK once). It's the gem BOUNDARY: not covered by unit tests (like
    # the Executor's create_chat); the Recorder's logic is tested with a fake tracer.
    def setup(service_name: "insika", env: ENV)
      return nil unless enabled?(env)

      require "opentelemetry/sdk"
      require "opentelemetry/exporter/otlp"
      load_metrics_sdk
      unless @configured
        OpenTelemetry::SDK.configure { |c| c.service_name = service_name }
        @configured = true
      end
      meter = otel_meter
      @metrics = !meter.nil?
      Recorder.new(tracer: OTelTracer.new(OpenTelemetry.tracer_provider.tracer("insika")),
                   meter: meter, pricing: pricing(env))
    end

    # Did `setup` wire the metric instruments too (SDK present, at least one reader)?
    # Only meaningful after `setup` — it exists for the boot banners.
    def metrics? = @metrics == true

    # Wires the Recorder to the Event Stream: subscribes to ALL events and feeds the
    # recorder in a long-lived fiber (sibling of serving). Call INSIDE the reactor
    # (serving arm). No-op if recorder is nil. -> the Subscription (or nil).
    def attach(event_stream:, recorder:, parent: nil)
      return nil if recorder.nil? # nil BEFORE touching the reactor (disabled path)

      parent ||= Async::Task.current
      sub = event_stream.subscribe
      parent.async { sub.each { |e| recorder.record(e) } }
      sub
    end

    # Operator-declared rates (USD per million tokens) as JSON in
    # INSIKA_MODEL_PRICING. Unset/malformed -> an empty table -> no cost is reported.
    def pricing(env = ENV)
      table = Pricing.parse(Insika::EnvSchema.read("INSIKA_MODEL_PRICING", env))
      table.empty? ? nil : table
    end

    def truthy(value) = %w[1 true yes on].include?(value.to_s.strip.downcase)
    def present?(value) = Insika::Coercion.present?(value)

    # The metrics SDK is OPTIONAL: absent from the bundle -> traces only, never a
    # boot failure. Present -> `SDK.configure` picks it up and registers the
    # periodic reader from the standard OTEL_METRICS_* env.
    def load_metrics_sdk
      require "opentelemetry-metrics-sdk"
      require "opentelemetry-exporter-otlp-metrics"
      @metrics_sdk = true
    rescue LoadError
      @metrics_sdk = false
    end

    # -> the OTEL meter | nil. nil whenever nothing would drain the instruments —
    # SDK absent, or every metric reader disabled (`OTEL_METRICS_EXPORTER=none`).
    # Recording into a provider with no reader would accumulate a point per
    # attribute set forever, so "no reader" MUST mean "no meter".
    def otel_meter
      return nil unless @metrics_sdk

      provider = OpenTelemetry.meter_provider
      return nil unless provider.respond_to?(:metric_readers) && !provider.metric_readers.empty?

      provider.meter("insika")
    end

    # --- OTEL adapters (gem boundary; only instantiated after setup's require).
    # They hide OpenTelemetry:: from the Recorder — which stays testable without the gem.

    # Translates the Recorder's duck-typed contract to the OTEL tracer.
    class OTelTracer
      def initialize(otel) = (@otel = otel)

      def start_span(name, parent:, attributes:, start_time:)
        ctx = parent ? OpenTelemetry::Trace.context_with_span(parent.raw) : OpenTelemetry::Context.current
        OTelSpan.new(@otel.start_span(name, with_parent: ctx, attributes: attributes, start_timestamp: start_time))
      end
    end

    class OTelSpan
      attr_reader :raw

      def initialize(raw) = (@raw = raw)
      def set_attribute(key, value) = @raw.set_attribute(key, value)
      def record_error(message) = (@raw.status = OpenTelemetry::Trace::Status.error(message))
      def finish(end_time:) = @raw.finish(end_timestamp: end_time)
    end
  end
end

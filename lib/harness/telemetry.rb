# frozen_string_literal: true

require "async"
require_relative "telemetry/recorder"

module Harness
  # OPT-IN observability (Phase 6): OTEL mounted at the edge, core untouched. Rides
  # the Event Stream — the Recorder consumes the events and emits spans. Off (the
  # default) -> `setup` returns nil and nothing is loaded or instrumented
  # (parity, zero overhead). The OTEL gem is only REQUIRED lazily in `setup`
  # (enabled), never at core load — like ruby_llm in the Executor.
  #
  # Turn on: `HARNESS_OTEL=1` OR the standard OTEL envs
  # (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_EXPORTER`). The destination/protocol
  # follows the OTEL SDK's default config (env) — SigNoz/Tempo/Jaeger/Collector.
  module Telemetry
    module_function

    def enabled?(env = ENV)
      truthy(env["HARNESS_OTEL"]) ||
        present?(env["OTEL_EXPORTER_OTLP_ENDPOINT"]) ||
        present?(env["OTEL_TRACES_EXPORTER"])
    end

    # -> Recorder wired to the real OTEL | nil (disabled). Idempotent per process
    # (configures the SDK once). It's the gem BOUNDARY: not covered by unit tests (like
    # the Executor's create_chat); the Recorder's logic is tested with a fake tracer.
    def setup(service_name: "harness", env: ENV)
      return nil unless enabled?(env)

      require "opentelemetry/sdk"
      require "opentelemetry/exporter/otlp"
      unless @configured
        OpenTelemetry::SDK.configure { |c| c.service_name = service_name }
        @configured = true
      end
      Recorder.new(tracer: OTelTracer.new(OpenTelemetry.tracer_provider.tracer("harness")))
    end

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

    def truthy(value) = %w[1 true yes on].include?(value.to_s.strip.downcase)
    def present?(value) = !value.to_s.strip.empty?

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

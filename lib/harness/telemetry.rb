# frozen_string_literal: true

require "async"
require_relative "telemetry/recorder"

module Harness
  # Observabilidade OPT-IN (Fase 6): OTEL montado na borda, núcleo intacto. Rides
  # o Event Stream — o Recorder consome os eventos e emite spans. Desligado (o
  # default) -> `setup` devolve nil e nada é carregado nem instrumentado
  # (paridade, zero overhead). A gem OTEL só é REQUERIDA lazy em `setup`
  # (habilitado), nunca no load do núcleo — como o ruby_llm no Executor.
  #
  # Ligar: `HARNESS_OTEL=1` OU as envs padrão do OTEL
  # (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_EXPORTER`). O destino/protocolo
  # segue a config padrão do SDK OTEL (env) — SigNoz/Tempo/Jaeger/Collector.
  module Telemetry
    module_function

    def enabled?(env = ENV)
      truthy(env["HARNESS_OTEL"]) ||
        present?(env["OTEL_EXPORTER_OTLP_ENDPOINT"]) ||
        present?(env["OTEL_TRACES_EXPORTER"])
    end

    # -> Recorder ligado ao OTEL real | nil (desligado). Idempotente por processo
    # (configura o SDK uma vez). É o BOUNDARY da gem: não coberto por unit (como o
    # create_chat do Executor); a lógica do Recorder é testada com tracer fake.
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

    # Liga o Recorder ao Event Stream: assina TODOS os eventos e alimenta o
    # recorder num fiber de vida-longa (irmão do serving). Chamar DENTRO do reactor
    # (arm de serving). No-op se recorder nil. -> a Subscription (ou nil).
    def attach(event_stream:, recorder:, parent: nil)
      return nil if recorder.nil? # nil ANTES de tocar o reactor (path desligado)

      parent ||= Async::Task.current
      sub = event_stream.subscribe
      parent.async { sub.each { |e| recorder.record(e) } }
      sub
    end

    def truthy(value) = %w[1 true yes on].include?(value.to_s.strip.downcase)
    def present?(value) = !value.to_s.strip.empty?

    # --- Adapters OTEL (boundary da gem; só instanciados após o require de setup).
    # Escondem OpenTelemetry:: do Recorder — este fica testável sem a gem.

    # Traduz o contrato duck-typed do Recorder para o tracer OTEL.
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

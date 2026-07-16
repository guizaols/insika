# frozen_string_literal: true

require "spec_helper"
require "async"

# Fase 6 — a fachada Telemetry: opt-in (enabled?), setup no-op quando desligado,
# e attach ligando o Event Stream ao Recorder. O boundary OTEL real (setup ligado)
# não é coberto por unit (puxa a gem); aqui provamos a lógica de borda.
RSpec.describe Harness::Telemetry do
  describe ".enabled?" do
    it "false sem envs (default — paridade, zero overhead)" do
      expect(described_class.enabled?({})).to be(false)
    end

    it "true com HARNESS_OTEL truthy" do
      expect(described_class.enabled?({ "HARNESS_OTEL" => "1" })).to be(true)
      expect(described_class.enabled?({ "HARNESS_OTEL" => "true" })).to be(true)
      expect(described_class.enabled?({ "HARNESS_OTEL" => "0" })).to be(false)
    end

    it "true com as envs padrão do OTEL" do
      expect(described_class.enabled?({ "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://collector:4318" })).to be(true)
      expect(described_class.enabled?({ "OTEL_TRACES_EXPORTER" => "otlp" })).to be(true)
    end
  end

  describe ".setup" do
    it "desligado -> nil (não carrega a gem OTEL)" do
      expect(described_class.setup(env: {})).to be_nil
    end
  end

  describe ".attach" do
    it "recorder nil -> no-op (nil), não assina" do
      es = Harness::EventStream.new
      expect(described_class.attach(event_stream: es, recorder: nil)).to be_nil
    end

    it "alimenta o recorder com os eventos do stream" do
      es = Harness::EventStream.new
      spy = []
      recorder = Object.new.tap { |r| r.define_singleton_method(:record) { |e| spy << e.type } }

      Sync do
        sub = described_class.attach(event_stream: es, recorder: recorder)
        es.emit(Harness::Event.new(type: :task_started, data: {}, meta: { task_id: "t" }))
        es.emit(Harness::Event.new(type: :task_completed, data: {}, meta: { task_id: "t" }))
        sub.close # drena os 2 eventos e encerra o consumidor
      end

      expect(spy).to eq(%i[task_started task_completed])
    end
  end
end

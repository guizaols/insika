# frozen_string_literal: true

require "spec_helper"
require "async"

# Phase 6 — the Telemetry facade: opt-in (enabled?), no-op setup when disabled,
# and attach wiring the Event Stream to the Recorder. The real OTEL boundary (setup on)
# is not covered by unit (pulls in the gem); here we prove the edge logic.
RSpec.describe Insika::Telemetry do
  describe ".enabled?" do
    it "false without envs (default — parity, zero overhead)" do
      expect(described_class.enabled?({})).to be(false)
    end

    it "true with INSIKA_OTEL truthy" do
      expect(described_class.enabled?({ "INSIKA_OTEL" => "1" })).to be(true)
      expect(described_class.enabled?({ "INSIKA_OTEL" => "true" })).to be(true)
      expect(described_class.enabled?({ "INSIKA_OTEL" => "0" })).to be(false)
    end

    it "still honors the deprecated HARNESS_OTEL alias" do
      expect(described_class.enabled?({ "HARNESS_OTEL" => "1" })).to be(true)
    end

    it "true with the standard OTEL envs" do
      expect(described_class.enabled?({ "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://collector:4318" })).to be(true)
      expect(described_class.enabled?({ "OTEL_TRACES_EXPORTER" => "otlp" })).to be(true)
    end
  end

  describe ".setup" do
    it "disabled -> nil (does not load the OTEL gem)" do
      expect(described_class.setup(env: {})).to be_nil
    end
  end

  describe ".attach" do
    it "recorder nil -> no-op (nil), does not subscribe" do
      es = Insika::EventStream.new
      expect(described_class.attach(event_stream: es, recorder: nil)).to be_nil
    end

    it "feeds the recorder with the stream events" do
      es = Insika::EventStream.new
      spy = []
      recorder = Object.new.tap { |r| r.define_singleton_method(:record) { |e| spy << e.type } }

      Sync do
        sub = described_class.attach(event_stream: es, recorder: recorder)
        es.emit(Insika::Event.new(type: :task_started, data: {}, meta: { task_id: "t" }))
        es.emit(Insika::Event.new(type: :task_completed, data: {}, meta: { task_id: "t" }))
        sub.close # drains the 2 events and closes the consumer
      end

      expect(spy).to eq(%i[task_started task_completed])
    end
  end
end

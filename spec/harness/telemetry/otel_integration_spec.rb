# frozen_string_literal: true

require "spec_helper"

# Phase 6 — smoke test of the real OTEL BOUNDARY (OTelTracer/OTelSpan): drains the
# Recorder against the real OTEL SDK, with an in-memory exporter, and checks that the
# exported spans have the right name/attributes/hierarchy. This is what the unit (fake
# tracer) does not cover: that the adapters call the gem correctly
# (with_parent/start_timestamp/set_attribute/finish/Status.error). Skipped if the
# gem is not available.
begin
  require "opentelemetry/sdk"
  OTEL_AVAILABLE = true
rescue LoadError
  OTEL_AVAILABLE = false
end

RSpec.describe "Harness::Telemetry — real OTEL boundary", if: OTEL_AVAILABLE do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) do
    p = OpenTelemetry::SDK::Trace::TracerProvider.new
    p.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    p
  end
  let(:recorder) do
    Harness::Telemetry::Recorder.new(tracer: Harness::Telemetry::OTelTracer.new(provider.tracer("harness-test")))
  end

  def ev(type, data = {}, at: "2026-07-15T12:00:00Z")
    Harness::Event.new(type: type, data: data, meta: { task_id: "t1", session_id: "chat-9", at: at })
  end

  it "exports a turn span with attributes (agent/tokens/status) via the real SDK" do
    recorder.record(ev(:task_started, { agent: "bia", command: "send_message" }, at: "2026-07-15T12:00:00Z"))
    recorder.record(ev(:task_completed, { usage: { input_tokens: 12, output_tokens: 8, total_tokens: 20, model: "deepseek" } },
                       at: "2026-07-15T12:00:02Z"))

    turn = exporter.finished_spans.find { |s| s.name == "harness.turn" }
    expect(turn).not_to be_nil
    expect(turn.attributes).to include("harness.agent" => "bia", "harness.status" => "ok",
                                       "harness.tokens.total" => 20, "harness.model" => "deepseek")
  end

  it "nests the tool span under the turn span (real parent)" do
    recorder.record(ev(:task_started, { agent: "bia" }))
    recorder.record(ev(:tool_call, { name: "search" }, at: "2026-07-15T12:00:01Z"))
    recorder.record(ev(:tool_result, { name: "search" }, at: "2026-07-15T12:00:02Z"))
    recorder.record(ev(:task_completed, {}, at: "2026-07-15T12:00:03Z"))

    spans = exporter.finished_spans
    turn = spans.find { |s| s.name == "harness.turn" }
    tool = spans.find { |s| s.name == "harness.tool" }
    expect(tool.parent_span_id).to eq(turn.span_id)          # same trace, child of the turn
    expect(tool.trace_id).to eq(turn.trace_id)
  end

  it "task_failed marks the span status as error (real Status.error)" do
    recorder.record(ev(:task_started, { agent: "bia" }))
    recorder.record(ev(:task_failed, { message: "estourou" }))

    turn = exporter.finished_spans.find { |s| s.name == "harness.turn" }
    expect(turn.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end
end

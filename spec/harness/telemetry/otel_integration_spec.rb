# frozen_string_literal: true

require "spec_helper"

# Fase 6 — smoke do BOUNDARY OTEL real (OTelTracer/OTelSpan): drena o Recorder
# contra o SDK OTEL de verdade, com um exporter em memória, e confere que os
# spans exportados têm nome/atributos/hierarquia certos. É o que o unit (tracer
# fake) não cobre: que os adapters chamam a gem corretamente
# (with_parent/start_timestamp/set_attribute/finish/Status.error). Pulado se a
# gem não estiver disponível.
begin
  require "opentelemetry/sdk"
  OTEL_AVAILABLE = true
rescue LoadError
  OTEL_AVAILABLE = false
end

RSpec.describe "Harness::Telemetry — boundary OTEL real", if: OTEL_AVAILABLE do
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

  it "exporta um span de turno com atributos (agente/tokens/status) via o SDK real" do
    recorder.record(ev(:task_started, { agent: "bia", command: "send_message" }, at: "2026-07-15T12:00:00Z"))
    recorder.record(ev(:task_completed, { usage: { input_tokens: 12, output_tokens: 8, total_tokens: 20, model: "deepseek" } },
                       at: "2026-07-15T12:00:02Z"))

    turn = exporter.finished_spans.find { |s| s.name == "harness.turn" }
    expect(turn).not_to be_nil
    expect(turn.attributes).to include("harness.agent" => "bia", "harness.status" => "ok",
                                       "harness.tokens.total" => 20, "harness.model" => "deepseek")
  end

  it "aninha o span de tool sob o span de turno (parent real)" do
    recorder.record(ev(:task_started, { agent: "bia" }))
    recorder.record(ev(:tool_call, { name: "search" }, at: "2026-07-15T12:00:01Z"))
    recorder.record(ev(:tool_result, { name: "search" }, at: "2026-07-15T12:00:02Z"))
    recorder.record(ev(:task_completed, {}, at: "2026-07-15T12:00:03Z"))

    spans = exporter.finished_spans
    turn = spans.find { |s| s.name == "harness.turn" }
    tool = spans.find { |s| s.name == "harness.tool" }
    expect(tool.parent_span_id).to eq(turn.span_id)          # mesmo trace, filho do turno
    expect(tool.trace_id).to eq(turn.trace_id)
  end

  it "task_failed marca o status do span como erro (Status.error real)" do
    recorder.record(ev(:task_started, { agent: "bia" }))
    recorder.record(ev(:task_failed, { message: "estourou" }))

    turn = exporter.finished_spans.find { |s| s.name == "harness.turn" }
    expect(turn.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end
end

# frozen_string_literal: true

require "spec_helper"

# smoke test of the real OTEL BOUNDARY (OTelTracer/OTelSpan): drains the
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

begin
  require "opentelemetry-metrics-sdk"
  OTEL_METRICS_AVAILABLE = true
rescue LoadError
  OTEL_METRICS_AVAILABLE = false
end

RSpec.describe "Insika::Telemetry — real OTEL boundary", if: OTEL_AVAILABLE do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) do
    p = OpenTelemetry::SDK::Trace::TracerProvider.new
    p.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    p
  end
  let(:recorder) do
    Insika::Telemetry::Recorder.new(tracer: Insika::Telemetry::OTelTracer.new(provider.tracer("insika-test")))
  end

  def ev(type, data = {}, at: "2026-07-15T12:00:00Z")
    Insika::Event.new(type: type, data: data, meta: { task_id: "t1", session_id: "chat-9", at: at })
  end

  it "exports a turn span with attributes (agent/tokens/status) via the real SDK" do
    recorder.record(ev(:task_started, { agent: "bia", command: "send_message" }, at: "2026-07-15T12:00:00Z"))
    recorder.record(ev(:task_completed, { usage: { input_tokens: 12, output_tokens: 8, total_tokens: 20, model: "deepseek" } },
                       at: "2026-07-15T12:00:02Z"))

    turn = exporter.finished_spans.find { |s| s.name == "insika.turn" }
    expect(turn).not_to be_nil
    expect(turn.attributes).to include("insika.agent" => "bia", "insika.status" => "ok",
                                       "insika.tokens.total" => 20, "insika.model" => "deepseek")
  end

  it "nests the tool span under the turn span (real parent)" do
    recorder.record(ev(:task_started, { agent: "bia" }))
    recorder.record(ev(:tool_call, { name: "search" }, at: "2026-07-15T12:00:01Z"))
    recorder.record(ev(:tool_result, { name: "search" }, at: "2026-07-15T12:00:02Z"))
    recorder.record(ev(:task_completed, {}, at: "2026-07-15T12:00:03Z"))

    spans = exporter.finished_spans
    turn = spans.find { |s| s.name == "insika.turn" }
    tool = spans.find { |s| s.name == "insika.tool" }
    expect(tool.parent_span_id).to eq(turn.span_id)          # same trace, child of the turn
    expect(tool.trace_id).to eq(turn.trace_id)
  end

  it "task_failed marks the span status as error (real Status.error)" do
    recorder.record(ev(:task_started, { agent: "bia" }))
    recorder.record(ev(:task_failed, { message: "estourou" }))

    turn = exporter.finished_spans.find { |s| s.name == "insika.turn" }
    expect(turn.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end
end

# — the METRICS boundary. Same idea as above: the Recorder talks to the
# real metrics SDK (in-memory pull exporter) so the instrument names/units/attributes
# of the documented convention are pinned against the gem, not only against a fake.
RSpec.describe "Insika::Telemetry — real OTEL metrics boundary", if: OTEL_METRICS_AVAILABLE do
  let(:exporter) { OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new }
  let(:provider) do
    OpenTelemetry::SDK::Metrics::MeterProvider.new.tap { |p| p.add_metric_reader(exporter) }
  end
  let(:recorder) do
    Insika::Telemetry::Recorder.new(
      tracer: Insika::Telemetry::OTelTracer.new(OpenTelemetry::SDK::Trace::TracerProvider.new.tracer("t")),
      meter: provider.meter("insika-test"),
      pricing: Insika::Telemetry::Pricing.new({ "m" => { "input" => 1.0, "output" => 0.0 } })
    )
  end

  def ev(type, data = {}, at: "2026-07-15T12:00:00Z")
    Insika::Event.new(type: type, data: data, meta: { task_id: "t1", session_id: "chat-9", at: at })
  end

  def snapshot(name)
    exporter.pull
    exporter.metric_snapshots.find { |s| s.name == name }
  end

  it "exports the turn counter and the duration histogram with the documented units" do
    recorder.record(ev(:task_started, { agent: "bia", tenant: "loja-42", command: "send_message" }))
    recorder.record(ev(:task_completed, { usage: { model: "m", input_tokens: 1_000_000, output_tokens: 0 } },
                       at: "2026-07-15T12:00:04Z"))

    turns = snapshot("insika.turns")
    expect(turns.unit).to eq("{turn}")
    expect(turns.data_points.first.value).to eq(1)
    expect(turns.data_points.first.attributes)
      .to include("insika.agent" => "bia", "insika.tenant" => "loja-42", "insika.status" => "ok")

    duration = snapshot("insika.turn.duration")
    expect(duration.unit).to eq("s")
    expect(duration.data_points.first.sum).to eq(4.0)
  end

  it "exports tokens split by type and the estimated cost in USD" do
    recorder.record(ev(:task_started, { agent: "bia" }))
    recorder.record(ev(:task_completed, { usage: { model: "m", input_tokens: 1_000_000, output_tokens: 8 } }))

    tokens = snapshot("insika.tokens")
    expect(tokens.data_points.map { |d| [d.attributes["insika.token.type"], d.value] })
      .to contain_exactly(["input", 1_000_000], ["output", 8])

    cost = snapshot("insika.cost")
    expect(cost.unit).to eq("{USD}")
    expect(cost.data_points.first.value).to eq(1.0)
  end
end

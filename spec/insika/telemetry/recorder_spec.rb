# frozen_string_literal: true

require "spec_helper"
require "time"

# Phase 6 — the Recorder translates Events -> OTEL spans. Tested with a FAKE tracer
# (the real OTEL adapter is a boundary, like create_chat). Proves: 1 span per turn,
# correlated tool child spans, attributes (agent/model/tokens/status),
# meta.at timestamps, robustness (never raises; orphans ignored).
RSpec.describe Insika::Telemetry::Recorder do
  # fake span: records attributes, error, completion.
  class FakeSpan
    attr_reader :name, :parent, :attributes, :start_time, :end_time, :error

    def initialize(name, parent, attributes, start_time)
      @name = name
      @parent = parent
      @attributes = attributes.dup
      @start_time = start_time
      @finished = false
    end

    def set_attribute(key, value) = (@attributes[key] = value)
    def record_error(message) = (@error = message)
    def finish(end_time:) = (@end_time = end_time; @finished = true)
    def finished? = @finished
  end

  class FakeTracer
    attr_reader :spans

    def initialize = (@spans = [])

    def start_span(name, parent:, attributes:, start_time:)
      span = FakeSpan.new(name, parent, attributes, start_time)
      @spans << span
      span
    end
  end

  # fake instrument/meter: records every (value, attributes) pair the Recorder emits.
  class FakeInstrument
    attr_reader :name, :unit, :points

    def initialize(name, unit)
      @name = name
      @unit = unit
      @points = []
    end

    def add(value, attributes:) = @points << [value, attributes]
    def record(value, attributes:) = @points << [value, attributes]
  end

  class FakeMeter
    attr_reader :instruments

    def initialize = (@instruments = {})

    def create_counter(name, unit: nil, description: nil) = build(name, unit, description)
    def create_histogram(name, unit: nil, description: nil) = build(name, unit, description)

    def [](name) = @instruments.fetch(name)

    private

    def build(name, unit, _description) = (@instruments[name] = FakeInstrument.new(name, unit))
  end

  let(:tracer) { FakeTracer.new }
  subject(:recorder) { described_class.new(tracer: tracer) }

  def ev(type, data = {}, task_id: "t1", at: "2026-07-15T12:00:00Z", session_id: "chat-9")
    Insika::Event.new(type: type, data: data, meta: { task_id: task_id, session_id: session_id, at: at })
  end

  def turn_span = tracer.spans.find { |s| s.name == "insika.turn" }

  describe "turn span" do
    it "task_started -> opens insika.turn with attributes and start_time; completed closes with tokens+status" do
      recorder.record(ev(:task_started, { agent: "bia", command: "send_message" }, at: "2026-07-15T12:00:00Z"))
      recorder.record(ev(:task_completed,
                         { content: "oi", usage: { input_tokens: 12, output_tokens: 8, total_tokens: 20, model: "deepseek" } },
                         at: "2026-07-15T12:00:03Z"))

      s = turn_span
      expect(s.name).to eq("insika.turn")
      expect(s.attributes).to include("insika.task_id" => "t1", "insika.session_id" => "chat-9",
                                      "insika.agent" => "bia", "insika.command" => "send_message",
                                      "insika.status" => "ok",
                                      "insika.tokens.input" => 12, "insika.tokens.output" => 8,
                                      "insika.tokens.total" => 20, "insika.model" => "deepseek")
      expect(s.start_time).to eq(Time.parse("2026-07-15T12:00:00Z"))
      expect(s.end_time).to eq(Time.parse("2026-07-15T12:00:03Z"))
      expect(s).to be_finished
    end

    it "does not inject a nil attribute (session/agent absent)" do
      recorder.record(ev(:task_started, { command: "send_message" }, session_id: nil))
      recorder.record(ev(:task_completed, {}))
      expect(turn_span.attributes).not_to include("insika.session_id")
      expect(turn_span.attributes).not_to include("insika.agent")
    end

    it "task_failed -> status error + record_error(message)" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      recorder.record(ev(:task_failed, { error: "Boom", message: "estourou" }))
      expect(turn_span.attributes["insika.status"]).to eq("error")
      expect(turn_span.error).to eq("estourou")
    end

    # Item 16 / P4: the tenant is the one operator-set grouping label; it rides the
    # :task_started payload (Executor#started_data) and is absent when unset.
    it "carries insika.tenant when the command declared one" do
      recorder.record(ev(:task_started, { agent: "bia", tenant: "loja-42" }))
      recorder.record(ev(:task_completed, {}))
      expect(turn_span.attributes["insika.tenant"]).to eq("loja-42")
    end

    it "no tenant declared -> no insika.tenant attribute" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      expect(turn_span.attributes).not_to include("insika.tenant")
    end

    it "reports cache-creation tokens and the resolved model_source" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      recorder.record(ev(:task_completed,
                         { usage: { input_tokens: 10, output_tokens: 2, cache_creation_tokens: 7,
                                    model: "deepseek-chat", model_source: "agent" } }))
      expect(turn_span.attributes).to include("insika.tokens.cache_creation" => 7,
                                              "insika.model_source" => "agent")
    end
  end

  # Item 16 / P4 — estimated cost. The Recorder does no arithmetic of its own: it
  # asks the injected Pricing, and reports nothing when there is no price.
  describe "estimated cost" do
    let(:pricing) { Insika::Telemetry::Pricing.new({ "m" => { "input" => 1.0, "output" => 2.0 } }) }
    subject(:recorder) { described_class.new(tracer: tracer, pricing: pricing) }

    it "priced model -> insika.cost.usd on the turn span" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      recorder.record(ev(:task_completed, { usage: { model: "m", input_tokens: 1_000_000, output_tokens: 0 } }))
      expect(turn_span.attributes["insika.cost.usd"]).to eq(1.0)
    end

    it "unpriced model -> no cost attribute (a gap, not a zero)" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      recorder.record(ev(:task_completed, { usage: { model: "unknown", input_tokens: 999, output_tokens: 1 } }))
      expect(turn_span.attributes).not_to include("insika.cost.usd")
    end

    it "no pricing injected -> no cost attribute" do
      plain = described_class.new(tracer: tracer)
      plain.record(ev(:task_started, { agent: "bia" }))
      plain.record(ev(:task_completed, { usage: { model: "m", input_tokens: 1_000_000, output_tokens: 0 } }))
      expect(turn_span.attributes).not_to include("insika.cost.usd")
    end
  end

  describe "tool spans (children of the turn)" do
    before { recorder.record(ev(:task_started, { agent: "bia" }, at: "2026-07-15T12:00:00Z")) }

    it "tool_call/tool_result -> insika.tool child, FIFO-correlated, with duration" do
      recorder.record(ev(:tool_call, { name: "search" }, at: "2026-07-15T12:00:01Z"))
      recorder.record(ev(:tool_result, { name: "search", result: "ok" }, at: "2026-07-15T12:00:02Z"))

      tool = tracer.spans.find { |s| s.name == "insika.tool" }
      expect(tool.attributes["insika.tool"]).to eq("search")
      expect(tool.parent).to eq(turn_span)                # child of the turn
      expect(tool.start_time).to eq(Time.parse("2026-07-15T12:00:01Z"))
      expect(tool.end_time).to eq(Time.parse("2026-07-15T12:00:02Z"))
      expect(tool).to be_finished
    end

    it "two tools in the same round close in FIFO" do
      recorder.record(ev(:tool_call, { name: "a" }))
      recorder.record(ev(:tool_call, { name: "b" }))
      recorder.record(ev(:tool_result, { name: "a" })) # closes the 1st open one (a)
      tools = tracer.spans.select { |s| s.name == "insika.tool" }
      expect(tools.map { |s| [s.attributes["insika.tool"], s.finished?] }).to eq([["a", true], ["b", false]])
    end

    it "data_tool_call -> point-in-time insika.data_tool with tool + http.status" do
      recorder.record(ev(:data_tool_call, { tool: "add_to_cart", status: 200 }, at: "2026-07-15T12:00:01Z"))
      dt = tracer.spans.find { |s| s.name == "insika.data_tool" }
      expect(dt.attributes).to include("insika.tool" => "add_to_cart", "insika.http.status" => 200)
      expect(dt.parent).to eq(turn_span)
      expect(dt.start_time).to eq(dt.end_time) # point-in-time
      expect(dt).to be_finished
    end

    it "a tool open when the turn fails is closed (no orphan span)" do
      recorder.record(ev(:tool_call, { name: "search" }))
      recorder.record(ev(:task_failed, { message: "x" }))
      expect(tracer.spans.find { |s| s.name == "insika.tool" }).to be_finished
    end
  end

  # Item 16 / P4 — metrics beside traces: the SAME events feed counters/histograms,
  # so a backend charts volume/latency/tokens/cost without aggregating spans. The
  # metric attribute set is a deliberate LOW-CARDINALITY subset (no task/session id).
  describe "metrics" do
    let(:meter) { FakeMeter.new }
    let(:pricing) { Insika::Telemetry::Pricing.new({ "m" => { "input" => 1.0, "output" => 0.0 } }) }
    subject(:recorder) { described_class.new(tracer: tracer, meter: meter, pricing: pricing) }

    def start(at: "2026-07-15T12:00:00Z")
      recorder.record(ev(:task_started, { agent: "bia", tenant: "loja-42", command: "send_message" }, at: at))
    end

    it "a finished turn counts once and records its duration, labelled by outcome" do
      start
      recorder.record(ev(:task_completed, { usage: { model: "m" } }, at: "2026-07-15T12:00:03Z"))

      labels = { "insika.agent" => "bia", "insika.tenant" => "loja-42",
                 "insika.command" => "send_message", "insika.status" => "ok", "insika.model" => "m" }
      expect(meter["insika.turns"].points).to eq([[1, labels]])
      expect(meter["insika.turn.duration"].points).to eq([[3.0, labels]])
    end

    it "the metric labels never carry task_id/session_id (cardinality contract)" do
      start
      recorder.record(ev(:task_completed, {}))
      keys = meter["insika.turns"].points.flat_map { |(_, a)| a.keys }
      expect(keys).not_to include("insika.task_id", "insika.session_id")
    end

    it "a failed turn is counted with status=error" do
      start
      recorder.record(ev(:task_failed, { message: "estourou" }))
      expect(meter["insika.turns"].points.dig(0, 1)).to include("insika.status" => "error")
    end

    it "tokens ride ONE counter split by insika.token.type" do
      start
      recorder.record(ev(:task_completed,
                         { usage: { model: "m", input_tokens: 12, output_tokens: 8, cached_tokens: 5,
                                    cache_creation_tokens: 3 } }))
      by_type = meter["insika.tokens"].points.to_h { |(n, a)| [a["insika.token.type"], n] }
      expect(by_type).to eq("input" => 12, "output" => 8, "cached" => 5, "cache_creation" => 3)
    end

    it "estimated cost lands on the insika.cost counter in USD" do
      start
      recorder.record(ev(:task_completed, { usage: { model: "m", input_tokens: 2_000_000, output_tokens: 0 } }))
      expect(meter["insika.cost"].points).to eq([[2.0, { "insika.agent" => "bia", "insika.tenant" => "loja-42",
                                                         "insika.command" => "send_message",
                                                         "insika.model" => "m" }]])
      expect(meter["insika.cost"].unit).to eq("{USD}")
    end

    it "an unpriced model contributes no cost point" do
      start
      recorder.record(ev(:task_completed, { usage: { model: "unknown", input_tokens: 5, output_tokens: 1 } }))
      expect(meter["insika.cost"].points).to be_empty
    end

    it "tool calls count with their duration and kind" do
      start
      recorder.record(ev(:tool_call, { name: "search" }, at: "2026-07-15T12:00:01Z"))
      recorder.record(ev(:tool_result, { name: "search" }, at: "2026-07-15T12:00:02Z"))

      labels = { "insika.agent" => "bia", "insika.tenant" => "loja-42", "insika.command" => "send_message",
                 "insika.tool" => "search", "insika.tool.kind" => "tool" }
      expect(meter["insika.tool.calls"].points).to eq([[1, labels]])
      expect(meter["insika.tool.duration"].points).to eq([[1.0, labels]])
    end

    it "data-tools count as kind=data_tool with the HTTP status, and record no duration" do
      start
      recorder.record(ev(:data_tool_call, { tool: "add_to_cart", status: 200 }))
      expect(meter["insika.tool.calls"].points.dig(0, 1))
        .to include("insika.tool.kind" => "data_tool", "insika.http.status" => 200)
      expect(meter["insika.tool.duration"].points).to be_empty # point-in-time event
    end

    it "an unfinished tool (turn failed mid-way) is not counted as a completed call" do
      start
      recorder.record(ev(:tool_call, { name: "search" }))
      recorder.record(ev(:task_failed, { message: "x" }))
      expect(meter["insika.tool.calls"].points).to be_empty
    end

    it "an unknown timestamp records no duration (never a made-up latency)" do
      start(at: nil)
      recorder.record(ev(:task_completed, {}, at: "2026-07-15T12:00:03Z"))
      expect(meter["insika.turns"].points.size).to eq(1)
      expect(meter["insika.turn.duration"].points).to be_empty
    end

    it "no meter injected -> spans only, no metric calls at all" do
      plain = described_class.new(tracer: tracer)
      plain.record(ev(:task_started, { agent: "bia" }))
      expect { plain.record(ev(:task_completed, { usage: { model: "m", input_tokens: 1 } })) }.not_to raise_error
      expect(meter.instruments).to be_empty
    end
  end

  describe "robustness" do
    it "orphan events (no turn) are ignored — does not raise, does not create a span" do
      recorder.record(ev(:tool_call, { name: "x" }))   # no task_started before
      recorder.record(ev(:tool_result, { name: "x" }))
      recorder.record(ev(:task_completed, {}))
      expect(tracer.spans).to be_empty
    end

    it "record NEVER raises (malformed event)" do
      bad = Insika::Event.new(type: :task_started, data: nil, meta: nil)
      expect { recorder.record(bad) }.not_to raise_error
    end

    it "meta.at absent -> start_time nil (span uses 'now' in the adapter)" do
      recorder.record(ev(:task_started, { agent: "bia" }, at: nil))
      expect(turn_span.start_time).to be_nil
    end
  end
end

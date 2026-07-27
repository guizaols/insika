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

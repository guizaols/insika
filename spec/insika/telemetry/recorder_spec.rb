# frozen_string_literal: true

require "spec_helper"
require "time"

# the Recorder translates Events -> OTEL spans. Tested with a FAKE tracer
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

    it "task_failed exports the exception class without its private message" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      recorder.record(ev(:task_failed, { error: "Boom", message: "estourou" }))
      expect(turn_span.attributes["insika.status"]).to eq("error")
      expect(turn_span.error).to eq("Boom")
    end

    # the tenant is the one operator-set grouping label; it rides the
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

  # — estimated cost. The Recorder does no arithmetic of its own: it
  # asks the injected Pricing, and reports nothing when there is no price.
  describe "estimated cost" do
    let(:pricing) { Insika::Telemetry::Pricing.new({ "m" => { "input" => 1.0, "output" => 2.0 } }) }
    subject(:recorder) { described_class.new(tracer: tracer, pricing: pricing) }

    it "reports recorded native cost without a custom pricing table" do
      plain = described_class.new(tracer: tracer)
      plain.record(ev(:task_started, { agent: "bia" }))
      plain.record(ev(:task_completed, { usage: { model: "m", input_tokens: 10, cost_usd: 0.012 } }))
      expect(turn_span.attributes["insika.cost.usd"]).to eq(0.012)
    end

    it "does not reprice unknown native cost as zero" do
      plain = described_class.new(tracer: tracer)
      plain.record(ev(:task_started, { agent: "bia" }))
      plain.record(ev(:task_completed, { usage: { model: "m", cost_usd: nil } }))
      expect(turn_span.attributes).not_to include("insika.cost.usd")
    end

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

  # — metrics beside traces: the SAME events feed counters/histograms,
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

    # — the cache-hit histogram. Same arithmetic as the Executor's
    # per-agent series: cached over the whole billed prompt (fresh + reads +
    # writes), so the rate is always in [0,100] and a full hit is 100, not "—".
    it "records the turn's cache-hit rate over the billed prompt" do
      start
      recorder.record(ev(:task_completed,
                         { usage: { model: "m", input_tokens: 60, cached_tokens: 30,
                                    cache_creation_tokens: 10 } }))
      expect(meter["insika.cache.hit_rate"].points)
        .to eq([[30.0, { "insika.agent" => "bia", "insika.tenant" => "loja-42",
                         "insika.command" => "send_message", "insika.model" => "m" }]])
      expect(meter["insika.cache.hit_rate"].unit).to eq("%")
    end

    it "a turn with no billed prompt tokens records no hit rate (absence, not 0%)" do
      start
      recorder.record(ev(:task_completed, {}))
      expect(meter["insika.cache.hit_rate"].points).to be_empty
    end

    # — the loop-detector counter. The event carries counts and the
    # tool name, never arguments; the metric inherits exactly that.
    it "counts a loop intervention with the turn labels and the tool name" do
      start
      recorder.record(ev(:tool_loop_intervened, { name: "search", streak: 3 }))
      expect(meter["insika.tool.loop_intervened"].points)
        .to eq([[1, { "insika.agent" => "bia", "insika.tenant" => "loja-42",
                      "insika.command" => "send_message", "insika.tool" => "search" }]])
    end

    it "an orphan loop event (no open turn) counts nothing" do
      recorder.record(ev(:tool_loop_intervened, { name: "search", streak: 3 }, task_id: "ghost"))
      expect(meter["insika.tool.loop_intervened"].points).to be_empty
    end

    # RFC-0044 — the compaction counter. It fires post-turn (usually after
    # task_completed already closed the span), so it rides its OWN labels
    # (agent + the summarizer's model), never the open-turn set.
    it "counts a persisted compaction by agent and summarizer model" do
      recorder.record(ev(:context_compacted,
                         { agent: "bia", model: "flash", from: 0, upto: 21, runs: 1 }))
      expect(meter["insika.context.compacted"].points)
        .to eq([[1, { "insika.agent" => "bia", "insika.model" => "flash" }]])
      expect(meter["insika.context.compacted"].unit).to eq("{compaction}")
    end

    it "a compaction with NO open turn still counts (post-terminal by design)" do
      recorder.record(ev(:context_compacted, { agent: "bia", model: "flash" }, task_id: "ghost"))
      expect(meter["insika.context.compacted"].points.size).to eq(1)
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
  describe "native request diagnostics" do
    let(:meter) { FakeMeter.new }
    subject(:recorder) { described_class.new(tracer: tracer, meter: meter) }

    it "labels rerank cost separately and totals it once with chat cost" do
      recorder.record(ev(:task_started, { agent: "a" }))
      recorder.record(ev(:llm_request, { "operation" => "rerank", "request_id" => "rerank-1" }))
      recorder.record(ev(:llm_usage, { "operation" => "rerank", "request_id" => "rerank-1", "cost" => 0.03 }))
      recorder.record(ev(:task_completed, { usage: { cost_usd: 0.1 } }))
      expect(turn_span.attributes).to include("insika.cost.usd" => 0.1,
        "insika.cost.rerank_usd" => 0.03, "insika.cost.total_usd" => 0.13)
      expect(meter["insika.cost"].points.sum(&:first)).to eq(0.13)
    end

    it "leaves the rerank total unknown when a request lacks usage" do
      recorder.record(ev(:task_started, { agent: "a" }))
      recorder.record(ev(:llm_request, { "operation" => "rerank", "request_id" => "r1" }))
      recorder.record(ev(:llm_usage, { "operation" => "rerank", "request_id" => "r1", "cost" => 0.03 }))
      recorder.record(ev(:llm_request, { "operation" => "rerank", "request_id" => "r2" }))
      recorder.record(ev(:task_completed, { usage: { cost_usd: 0.1 } }))
      expect(turn_span.attributes).not_to include("insika.cost.rerank_usd", "insika.cost.total_usd")
    end

    it "leaves the rerank total unknown when native events were truncated" do
      recorder.record(ev(:task_started, { agent: "a" }))
      recorder.record(ev(:llm_request, { "operation" => "rerank", "request_id" => "r1" }))
      recorder.record(ev(:llm_usage, { "operation" => "rerank", "request_id" => "r1", "cost" => 0.03 }))
      (Insika::LLMTraceStore::MAX_PER_TASK - 1).times do |i|
        recorder.record(ev(:llm_request, { "operation" => "chat", "request_id" => "c#{i}" }))
      end
      recorder.record(ev(:task_completed, { usage: { cost_usd: 0.1 } }))
      expect(turn_span.attributes).not_to include("insika.cost.rerank_usd", "insika.cost.total_usd")
    end

    it "correlates interleaved and late attempts by request id without billing twice" do
      recorder.record(ev(:task_started, { agent: "a" }))
      recorder.record(ev(:llm_usage, { "request_id" => "r1", "status" => "failed", "input_tokens" => 3 }))
      recorder.record(ev(:llm_request, { "request_id" => "r2", "model" => "m2", "duration_ms" => 200, "status" => "succeeded" }, at: "2026-07-15T12:00:02.5Z"))
      recorder.record(ev(:llm_request, { "request_id" => "r1", "model" => "m1", "duration_ms" => 500, "status" => "succeeded" }, at: "2026-07-15T12:00:03.5Z"))
      recorder.record(ev(:llm_usage, { "request_id" => "r2", "status" => "succeeded", "input_tokens" => 8, "cost" => 0.1 }))
      recorder.record(ev(:llm_usage, { "request_id" => "r1", "status" => "succeeded", "input_tokens" => 9, "cost" => nil, "messages" => "secret" }))
      recorder.record(ev(:task_completed, { usage: { input_tokens: 17, cost_usd: 0.1 } }))
      requests = tracer.spans.select { |span| span.name == "insika.llm.request" }.to_h { |span| [span.attributes["insika.llm.request_id"], span] }
      expect(requests.keys).to contain_exactly("r1", "r2")
      expect(requests["r1"].parent).to eq(turn_span)
      expect(requests["r1"].attributes).to include("insika.llm.attempts" => 2, "insika.llm.failures" => 1,
        "insika.llm.attempt.1.input_tokens" => 3, "insika.llm.attempt.2.input_tokens" => 9)
      expect(requests["r1"].attributes).not_to have_key("insika.llm.attempt.2.cost")
      expect(requests["r1"].end_time - requests["r1"].start_time).to eq(0.5)
      expect(requests["r2"].attributes).to include("insika.llm.attempt.1.input_tokens" => 8)
      expect(requests.values).to all(be_finished)
      expect(requests.values.map(&:attributes).inspect).not_to include("secret")
      expect(meter["insika.tokens"].points.sum(&:first)).to eq(17)
      expect(meter["insika.cost"].points.sum(&:first)).to eq(0.1)
      expect(meter["insika.llm.attempts"].points.sum(&:first)).to eq(3)
      expect(meter["insika.llm.failures"].points.sum(&:first)).to eq(1)
    end

    it "discloses a truncated request history and still counts all attempts" do
      recorder.record(ev(:task_started))
      201.times { recorder.record(ev(:llm_usage, { "request_id" => "r", "status" => "failed" })) }
      recorder.record(ev(:llm_request, { "request_id" => "r", "status" => "failed", "duration_ms" => 1 }))
      recorder.record(ev(:task_failed, { message: "private", error: { message: "private" } }))
      request = tracer.spans.find { |span| span.name == "insika.llm.request" }
      expect(request.attributes).to include("insika.llm.truncated" => true, "insika.llm.attempts" => 199)
      expect(turn_span.attributes).to include("insika.llm.truncated" => true)
      expect(turn_span.error).to eq("Task failed")
      expect(meter["insika.llm.attempts"].points.sum(&:first)).to eq(201)
    end

    it "closes the turn when the model span exporter fails" do
      recorder.record(ev(:task_started))
      recorder.record(ev(:llm_request, { "request_id" => "r", "status" => "succeeded", "duration_ms" => 1 }))
      allow(tracer).to receive(:start_span).with("insika.llm.request", any_args).and_raise("private")
      expect { recorder.record(ev(:task_completed)) }.not_to raise_error
      expect(turn_span).to be_finished
    end

    it "isolates exporter failures" do
      allow(tracer).to receive(:start_span).and_raise("private exporter error")
      expect { recorder.record(ev(:task_started)) }.not_to raise_error
      expect { recorder.record(ev(:llm_request, { "request_id" => "r" })) }.not_to raise_error
    end
  end

end

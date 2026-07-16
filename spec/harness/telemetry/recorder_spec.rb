# frozen_string_literal: true

require "spec_helper"
require "time"

# Fase 6 — o Recorder traduz Events -> spans OTEL. Testado com um tracer FAKE
# (o adapter OTEL real é boundary, como o create_chat). Prova: 1 span por turno,
# spans-filho de tool correlacionados, atributos (agente/modelo/tokens/status),
# timestamps do meta.at, robustez (nunca levanta; órfãos ignorados).
RSpec.describe Harness::Telemetry::Recorder do
  # span fake: registra atributos, erro, término.
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
    Harness::Event.new(type: type, data: data, meta: { task_id: task_id, session_id: session_id, at: at })
  end

  def turn_span = tracer.spans.find { |s| s.name == "harness.turn" }

  describe "span de turno" do
    it "task_started -> abre harness.turn com atributos e start_time; completed fecha com tokens+status" do
      recorder.record(ev(:task_started, { agent: "bia", command: "send_message" }, at: "2026-07-15T12:00:00Z"))
      recorder.record(ev(:task_completed,
                         { content: "oi", usage: { input_tokens: 12, output_tokens: 8, total_tokens: 20, model: "deepseek" } },
                         at: "2026-07-15T12:00:03Z"))

      s = turn_span
      expect(s.name).to eq("harness.turn")
      expect(s.attributes).to include("harness.task_id" => "t1", "harness.session_id" => "chat-9",
                                      "harness.agent" => "bia", "harness.command" => "send_message",
                                      "harness.status" => "ok",
                                      "harness.tokens.input" => 12, "harness.tokens.output" => 8,
                                      "harness.tokens.total" => 20, "harness.model" => "deepseek")
      expect(s.start_time).to eq(Time.parse("2026-07-15T12:00:00Z"))
      expect(s.end_time).to eq(Time.parse("2026-07-15T12:00:03Z"))
      expect(s).to be_finished
    end

    it "não injeta atributo nil (session/agent ausentes)" do
      recorder.record(ev(:task_started, { command: "send_message" }, session_id: nil))
      recorder.record(ev(:task_completed, {}))
      expect(turn_span.attributes).not_to include("harness.session_id")
      expect(turn_span.attributes).not_to include("harness.agent")
    end

    it ":done é ignorado (gêmeo legado do :task_completed — sem span/finish duplo)" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      recorder.record(ev(:done, { content: "oi" }))       # ignorado
      expect(turn_span).not_to be_finished                # ainda aberto
      recorder.record(ev(:task_completed, {}))
      expect(tracer.spans.count { |s| s.name == "harness.turn" }).to eq(1)
      expect(turn_span).to be_finished
    end

    it "task_failed -> status error + record_error(message)" do
      recorder.record(ev(:task_started, { agent: "bia" }))
      recorder.record(ev(:task_failed, { error: "Boom", message: "estourou" }))
      expect(turn_span.attributes["harness.status"]).to eq("error")
      expect(turn_span.error).to eq("estourou")
    end
  end

  describe "spans de tool (filhos do turno)" do
    before { recorder.record(ev(:task_started, { agent: "bia" }, at: "2026-07-15T12:00:00Z")) }

    it "tool_call/tool_result -> harness.tool filho, correlacionado FIFO, com duração" do
      recorder.record(ev(:tool_call, { name: "search" }, at: "2026-07-15T12:00:01Z"))
      recorder.record(ev(:tool_result, { name: "search", result: "ok" }, at: "2026-07-15T12:00:02Z"))

      tool = tracer.spans.find { |s| s.name == "harness.tool" }
      expect(tool.attributes["harness.tool"]).to eq("search")
      expect(tool.parent).to eq(turn_span)                # filho do turno
      expect(tool.start_time).to eq(Time.parse("2026-07-15T12:00:01Z"))
      expect(tool.end_time).to eq(Time.parse("2026-07-15T12:00:02Z"))
      expect(tool).to be_finished
    end

    it "duas tools na mesma volta fecham em FIFO" do
      recorder.record(ev(:tool_call, { name: "a" }))
      recorder.record(ev(:tool_call, { name: "b" }))
      recorder.record(ev(:tool_result, { name: "a" })) # fecha o 1º aberto (a)
      tools = tracer.spans.select { |s| s.name == "harness.tool" }
      expect(tools.map { |s| [s.attributes["harness.tool"], s.finished?] }).to eq([["a", true], ["b", false]])
    end

    it "data_tool_call -> harness.data_tool pontual com tool + http.status" do
      recorder.record(ev(:data_tool_call, { tool: "add_to_cart", status: 200 }, at: "2026-07-15T12:00:01Z"))
      dt = tracer.spans.find { |s| s.name == "harness.data_tool" }
      expect(dt.attributes).to include("harness.tool" => "add_to_cart", "harness.http.status" => 200)
      expect(dt.parent).to eq(turn_span)
      expect(dt.start_time).to eq(dt.end_time) # pontual
      expect(dt).to be_finished
    end

    it "tool aberta quando o turno falha é fechada (sem span órfão)" do
      recorder.record(ev(:tool_call, { name: "search" }))
      recorder.record(ev(:task_failed, { message: "x" }))
      expect(tracer.spans.find { |s| s.name == "harness.tool" }).to be_finished
    end
  end

  describe "robustez" do
    it "eventos órfãos (sem turno) são ignorados — não levanta, não cria span" do
      recorder.record(ev(:tool_call, { name: "x" }))   # sem task_started antes
      recorder.record(ev(:tool_result, { name: "x" }))
      recorder.record(ev(:task_completed, {}))
      expect(tracer.spans).to be_empty
    end

    it "record NUNCA levanta (evento malformado)" do
      bad = Harness::Event.new(type: :task_started, data: nil, meta: nil)
      expect { recorder.record(bad) }.not_to raise_error
    end

    it "meta.at ausente -> start_time nil (span usa 'agora' no adapter)" do
      recorder.record(ev(:task_started, { agent: "bia" }, at: nil))
      expect(turn_span.start_time).to be_nil
    end
  end
end

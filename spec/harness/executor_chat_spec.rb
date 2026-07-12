# frozen_string_literal: true

require "spec_helper"
require "harness/tools/load_skill" # o Executor o carrega lazy; explícito no teste
require "harness/tools/tool_search"

RSpec.describe "Harness::Executor estágios 5-7 (cola RubyLLM)" do
  # Spy síncrono de event_stream — evita a coreografia de fibers para os
  # callbacks (que aqui são disparados diretamente pelo FakeChat).
  class RecordingEventStream
    attr_reader :events

    def initialize = (@events = [])
    def emit(event) = @events << event
  end

  Ctx = Struct.new(:system)
  TaskStub = Struct.new(:id, :session_id)
  ProfileStub = Struct.new(:model, :provider, :limits)
  State = Struct.new(:context, :allowed_tools, :allowed_skills, :profile, :task,
                     :current_tool_call, keyword_init: true)

  let(:event_stream) { RecordingEventStream.new }
  let(:inert) { Object.new }
  let(:skill_catalog) { instance_double("Harness::SkillCatalog") }

  subject(:executor) do
    Harness::Executor.new(
      context_builder: inert, policy_engine: inert, middleware: inert,
      hooks: Harness::Hooks.new, # wire_callbacks usa run_before/run_after(:tool)
      tool_registry: inert, skill_catalog: skill_catalog, profiles: {},
      session_store: inert, task_store: inert, checkpoint_store: inert,
      event_stream: event_stream
    )
  end

  let(:chat) { FakeChat.new }
  let(:task) { TaskStub.new("t", "s") }

  def state(system: "SOUL", allowed_tools: [], allowed_skills: [], limits: {})
    State.new(context: Ctx.new(system), allowed_tools: allowed_tools,
              allowed_skills: allowed_skills, profile: ProfileStub.new("gpt", nil, limits),
              task: task)
  end

  describe "#configure_chat" do
    it "passa as instructions do Builder" do
      executor.send(:configure_chat, chat, state(system: "SOUL"))

      expect(chat.instructions).to eq("SOUL")
    end

    it "não chama with_instructions quando o system está vazio" do
      executor.send(:configure_chat, chat, state(system: ""))

      expect(chat.instructions).to be_nil
    end

    it "usa as tools da Resolution (instâncias prontas)" do
      t1 = Object.new
      t2 = Object.new
      executor.send(:configure_chat, chat, state(allowed_tools: [t1, t2]))

      expect(chat.tools).to contain_exactly(t1, t2)
    end

    it "adiciona LoadSkill de sistema quando há allowed_skills" do
      executor.send(:configure_chat, chat, state(allowed_tools: [Object.new], allowed_skills: ["cardapio"]))

      expect(chat.tools.size).to eq(2)
      expect(chat.tools.last).to be_a(Harness::Tools::LoadSkill)
    end

    it "não adiciona LoadSkill sem skills" do
      executor.send(:configure_chat, chat, state(allowed_tools: [Object.new], allowed_skills: []))

      expect(chat.tools.none? { |t| t.is_a?(Harness::Tools::LoadSkill) }).to be(true)
    end
  end

  describe "#configure_chat — Tool Search (partição eager/deferred, P2B task 10)" do
    def named_tool(name)
      Class.new { define_method(:name) { name }; def description = "d" }.new
    end

    let(:tool_registry) do
      reg = Harness::ToolRegistry.new
      reg.register("send_email") { named_tool("send_email") }
      reg
    end
    let(:tool_catalog) { Harness::ToolCatalog.new(tool_registry: tool_registry) }

    # Executor COM tool_catalog + tool_registry reais (as outras deps inertes).
    def exec_with_catalog
      Harness::Executor.new(
        context_builder: inert, policy_engine: inert, middleware: inert,
        hooks: Harness::Hooks.new, tool_registry: tool_registry, skill_catalog: skill_catalog,
        profiles: {}, session_store: inert, task_store: inert, checkpoint_store: inert,
        event_stream: event_stream, tool_catalog: tool_catalog
      )
    end

    def ts_state(allowed_tools:, tools_deferred:)
      profile = Harness::AgentProfile.build(id: "a", model: "gpt", tools_deferred: tools_deferred)
      State.new(context: Ctx.new("SOUL"), allowed_tools: allowed_tools, allowed_skills: [],
                profile: profile, task: TaskStub.new("t", "s"))
    end

    it "deferred sai do wiring eager e a builtin ToolSearch entra" do
      st = ts_state(allowed_tools: [named_tool("send_email"), named_tool("other")],
                    tools_deferred: ["send_email"])
      exec_with_catalog.send(:configure_chat, chat, st)

      names = chat.tools.map { |t| t.respond_to?(:name) ? t.name : nil }
      expect(names).to include("other")
      expect(names).not_to include("send_email") # deferido, não cabeado eager
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(true)
    end

    it "ToolSearch nunca é envelopada (instância direta, como load_skill)" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      exec_with_catalog.send(:configure_chat, chat, st)
      ts = chat.tools.find { |t| t.is_a?(Harness::Tools::ToolSearch) }
      expect(ts).not_to be_a(Harness::ToolEnvelope)
    end

    it "deferred_allowed = allowed ∩ tools_deferred (não o tools_deferred isolado)" do
      # tools_deferred inclui 'ghost' que a Policy não passou (não está em allowed)
      st = ts_state(allowed_tools: [named_tool("send_email")],
                    tools_deferred: %w[send_email ghost])
      exec_with_catalog.send(:configure_chat, chat, st)
      ts = chat.tools.find { |t| t.is_a?(Harness::Tools::ToolSearch) }
      expect(ts.instance_variable_get(:@deferred_allowed)).to eq(["send_email"])
    end

    it "paridade: sem tool_catalog, tudo eager e sem ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      # `executor` (subject padrão) NÃO tem tool_catalog
      executor.send(:configure_chat, chat, st)
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(false)
    end

    it "profile.tools_deferred nil (com tool_catalog): tudo eager, sem ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: nil)
      exec_with_catalog.send(:configure_chat, chat, st)
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(false)
    end
  end

  describe "#seed_history" do
    it "adiciona mensagens com role Symbol, na ordem, tolerando chaves string" do
      executor.send(:seed_history, chat, [
                      { role: :user, content: "oi" },
                      { "role" => "assistant", "content" => "olá" }
                    ])

      expect(chat.messages).to eq([
                                    { role: :user, content: "oi" },
                                    { role: :assistant, content: "olá" }
                                  ])
    end
  end

  describe "#wire_callbacks" do
    it "emite :tool_call e :tool_result com meta.task_id e seq crescente" do
      executor.send(:wire_callbacks, chat, state)
      chat.fire_tool_call(name: "lookup", arguments: { "q" => "x" })
      chat.fire_tool_result("resultado")

      types = event_stream.events.map(&:type)
      expect(types).to eq(%i[tool_call tool_result])
      call = event_stream.events.first
      expect(call.data).to eq({ name: "lookup", arguments: { "q" => "x" } })
      expect(call.meta[:task_id]).to eq("t")
      result = event_stream.events.last
      expect(result.data).to eq({ name: "lookup", result: "resultado" })
      expect(event_stream.events.map { |e| e.meta[:seq] }).to eq([1, 2])
    end

    it "emite :skill_activated (não :tool_call) para load_skill" do
      executor.send(:wire_callbacks, chat, state)
      chat.fire_tool_call(name: "load_skill", arguments: { "name" => "cardapio" })

      expect(event_stream.events.map(&:type)).to eq([:skill_activated])
      expect(event_stream.events.first.data).to eq({ name: "cardapio" })
    end

    it "aborta com TimeoutError(stage: :tool_limit) ao exceder max_tool_calls" do
      executor.send(:wire_callbacks, chat, state(limits: { max_tool_calls: 2 }))

      chat.fire_tool_call(name: "a")
      chat.fire_tool_call(name: "b")
      expect { chat.fire_tool_call(name: "c") }
        .to raise_error(Harness::TimeoutError) { |e| expect(e.stage).to eq(:tool_limit) }
    end

    it "usa o default de 50 quando limits não traz max_tool_calls" do
      executor.send(:wire_callbacks, chat, state(limits: {}))

      50.times { |i| chat.fire_tool_call(name: "t#{i}") }
      expect { chat.fire_tool_call(name: "t50") }.to raise_error(Harness::TimeoutError)
    end
  end
end

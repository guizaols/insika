# frozen_string_literal: true

require "spec_helper"
require "harness/tools/load_skill" # o Executor os carrega lazy em create_chat; explícito no teste
require "harness/tools/tool_search"
require "harness/tools/remember"

RSpec.describe Harness::ChatBuilder do
  Ctx = Struct.new(:system)
  TaskStub = Struct.new(:id, :session_id)
  ProfileStub = Struct.new(:model, :provider, :limits)
  State = Struct.new(:context, :allowed_tools, :allowed_skills, :profile, :task,
                     :current_tool_call, keyword_init: true)

  let(:inert) { Object.new }
  let(:skill_catalog) { instance_double("Harness::SkillCatalog") }
  let(:event_stream) { Object.new }

  # ChatBuilder mínimo (deps inertes salvo as que o teste exercita).
  def builder(tool_registry: inert, tool_catalog: nil, memory_store: nil, hooks: Harness::Hooks.new)
    described_class.new(tool_registry: tool_registry, skill_catalog: skill_catalog,
                        checkpoint_store: inert, event_stream: event_stream, hooks: hooks,
                        tool_catalog: tool_catalog, memory_store: memory_store)
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
      builder.configure_chat(chat, state(system: "SOUL"))
      expect(chat.instructions).to eq("SOUL")
    end

    it "não chama with_instructions quando o system está vazio" do
      builder.configure_chat(chat, state(system: ""))
      expect(chat.instructions).to be_nil
    end

    it "usa as tools da Resolution (instâncias prontas)" do
      t1 = Object.new
      t2 = Object.new
      builder.configure_chat(chat, state(allowed_tools: [t1, t2]))
      expect(chat.tools).to contain_exactly(t1, t2)
    end

    it "adiciona LoadSkill de sistema quando há allowed_skills" do
      builder.configure_chat(chat, state(allowed_tools: [Object.new], allowed_skills: ["cardapio"]))
      expect(chat.tools.size).to eq(2)
      expect(chat.tools.last).to be_a(Harness::Tools::LoadSkill)
    end

    it "não adiciona LoadSkill sem skills" do
      builder.configure_chat(chat, state(allowed_tools: [Object.new], allowed_skills: []))
      expect(chat.tools.none? { |t| t.is_a?(Harness::Tools::LoadSkill) }).to be(true)
    end
  end

  describe "#configure_chat — Tool Search (partição eager/deferred)" do
    def named_tool(name)
      Class.new { define_method(:name) { name }; def description = "d" }.new
    end

    let(:tool_registry) do
      reg = Harness::ToolRegistry.new
      reg.register("send_email") { named_tool("send_email") }
      reg
    end
    let(:tool_catalog) { Harness::ToolCatalog.new(tool_registry: tool_registry) }

    def builder_with_catalog
      builder(tool_registry: tool_registry, tool_catalog: tool_catalog)
    end

    def ts_state(allowed_tools:, tools_deferred:)
      profile = Harness::AgentProfile.build(id: "a", model: "gpt", tools_deferred: tools_deferred)
      State.new(context: Ctx.new("SOUL"), allowed_tools: allowed_tools, allowed_skills: [],
                profile: profile, task: TaskStub.new("t", "s"))
    end

    it "deferred sai do wiring eager e a builtin ToolSearch entra" do
      st = ts_state(allowed_tools: [named_tool("send_email"), named_tool("other")],
                    tools_deferred: ["send_email"])
      builder_with_catalog.configure_chat(chat, st)

      names = chat.tools.map { |t| t.respond_to?(:name) ? t.name : nil }
      expect(names).to include("other")
      expect(names).not_to include("send_email") # deferido, não cabeado eager
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(true)
    end

    it "ToolSearch nunca é envelopada (instância direta, como load_skill)" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      builder_with_catalog.configure_chat(chat, st)
      ts = chat.tools.find { |t| t.is_a?(Harness::Tools::ToolSearch) }
      expect(ts).not_to be_a(Harness::ToolEnvelope)
    end

    it "deferred_allowed = allowed ∩ tools_deferred (não o tools_deferred isolado)" do
      st = ts_state(allowed_tools: [named_tool("send_email")],
                    tools_deferred: %w[send_email ghost])
      builder_with_catalog.configure_chat(chat, st)
      ts = chat.tools.find { |t| t.is_a?(Harness::Tools::ToolSearch) }
      expect(ts.instance_variable_get(:@deferred_allowed)).to eq(["send_email"])
    end

    it "paridade: sem tool_catalog, tudo eager e sem ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      builder.configure_chat(chat, st) # builder sem tool_catalog
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(false)
    end

    it "profile.tools_deferred nil (com tool_catalog): tudo eager, sem ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: nil)
      builder_with_catalog.configure_chat(chat, st)
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(false)
    end
  end

  describe "#configure_chat — remember de sistema" do
    let(:mem) { Harness::MemoryStore.new(store: Harness::Stores::Memory.new) }

    def builder_with_memory
      builder(memory_store: mem)
    end

    def mem_state(memory:)
      profile = Harness::AgentProfile.build(id: "a", model: "gpt", memory: memory)
      st = Harness::TurnState.new(task: TaskStub.new("t", "s"), profile: profile, turn: 1, message: "oi")
      st.context = Ctx.new("SOUL")
      st.allowed_tools = []
      st.allowed_skills = []
      st.tenant = "acme"
      st
    end

    it "cabeia remember quando @memory_store + profile.memory" do
      builder_with_memory.configure_chat(chat, mem_state(memory: true))
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::Remember) }).to be(true)
    end

    it "remember nunca é envelopada (instância direta)" do
      builder_with_memory.configure_chat(chat, mem_state(memory: true))
      rt = chat.tools.find { |t| t.is_a?(Harness::Tools::Remember) }
      expect(rt).not_to be_a(Harness::ToolEnvelope)
    end

    it "profile.memory nil: sem remember (paridade)" do
      builder_with_memory.configure_chat(chat, mem_state(memory: nil))
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::Remember) }).to be(false)
    end

    it "sem @memory_store: sem remember mesmo com memory:true (paridade)" do
      builder.configure_chat(chat, mem_state(memory: true)) # builder sem memory_store
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::Remember) }).to be(false)
    end
  end

  describe "#seed_history" do
    it "adiciona mensagens com role Symbol, na ordem, tolerando chaves string" do
      builder.seed_history(chat, [
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
    # O ChatBuilder emite via o callable injetado; a numeração seq+meta é do
    # Executor#emit (coberto nos specs de pipeline). Aqui gravamos (type, data).
    def recording_emit(sink)
      ->(type, data) { sink << { type: type, data: data } }
    end

    it "emite :tool_call e :tool_result na ordem, com name e arguments" do
      sink = []
      builder.wire_callbacks(chat, state, recording_emit(sink))
      chat.fire_tool_call(name: "lookup", arguments: { "q" => "x" })
      chat.fire_tool_result("resultado")

      expect(sink.map { |e| e[:type] }).to eq(%i[tool_call tool_result])
      expect(sink.first[:data]).to eq({ name: "lookup", arguments: { "q" => "x" } })
      expect(sink.last[:data]).to eq({ name: "lookup", result: "resultado" })
    end

    it "emite :skill_activated (não :tool_call) para load_skill" do
      sink = []
      builder.wire_callbacks(chat, state, recording_emit(sink))
      chat.fire_tool_call(name: "load_skill", arguments: { "name" => "cardapio" })

      expect(sink.map { |e| e[:type] }).to eq([:skill_activated])
      expect(sink.first[:data]).to eq({ name: "cardapio" })
    end

    it "aborta com TimeoutError(stage: :tool_limit) ao exceder max_tool_calls" do
      builder.wire_callbacks(chat, state(limits: { max_tool_calls: 2 }), recording_emit([]))

      chat.fire_tool_call(name: "a")
      chat.fire_tool_call(name: "b")
      expect { chat.fire_tool_call(name: "c") }
        .to raise_error(Harness::TimeoutError) { |e| expect(e.stage).to eq(:tool_limit) }
    end

    it "usa o default de 50 quando limits não traz max_tool_calls" do
      builder.wire_callbacks(chat, state(limits: {}), recording_emit([]))

      50.times { |i| chat.fire_tool_call(name: "t#{i}") }
      expect { chat.fire_tool_call(name: "t50") }.to raise_error(Harness::TimeoutError)
    end
  end
end

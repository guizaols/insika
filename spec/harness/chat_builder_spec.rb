# frozen_string_literal: true

require "spec_helper"
require "harness/tools/load_skill" # the Executor loads them lazily in create_chat; explicit here in the test
require "harness/tools/tool_search"
require "harness/tools/remember"

RSpec.describe Harness::ChatBuilder do
  Ctx = Struct.new(:system)
  TaskStub = Struct.new(:id, :session_id)
  ProfileStub = Struct.new(:model, :provider, :limits, :prompt_caching)
  State = Struct.new(:context, :allowed_tools, :allowed_skills, :profile, :task,
                     :current_tool_call, keyword_init: true)

  let(:inert) { Object.new }
  let(:skill_catalog) { instance_double("Harness::SkillCatalog") }
  let(:event_stream) { Object.new }

  # Minimal ChatBuilder (inert deps except the ones the test exercises).
  def builder(tool_registry: inert, tool_catalog: nil, memory_store: nil, hooks: Harness::Hooks.new)
    described_class.new(tool_registry: tool_registry, skill_catalog: skill_catalog,
                        checkpoint_store: inert, event_stream: event_stream, hooks: hooks,
                        tool_catalog: tool_catalog, memory_store: memory_store)
  end

  let(:chat) { FakeChat.new }
  let(:task) { TaskStub.new("t", "s") }

  def state(system: "SOUL", allowed_tools: [], allowed_skills: [], limits: {}, prompt_caching: nil)
    State.new(context: Ctx.new(system), allowed_tools: allowed_tools,
              allowed_skills: allowed_skills,
              profile: ProfileStub.new("gpt", nil, limits, prompt_caching),
              task: task)
  end

  describe "#configure_chat" do
    it "passes the Builder's instructions" do
      builder.configure_chat(chat, state(system: "SOUL"))
      expect(chat.instructions).to eq("SOUL")
    end

    it "doesn't call with_instructions when the system is empty" do
      builder.configure_chat(chat, state(system: ""))
      expect(chat.instructions).to be_nil
    end

    context "prompt caching (§11 R3)" do
      before { require "ruby_llm" }

      def anthropic_chat
        FakeChat.new.tap { |c| c.model = Struct.new(:provider).new("anthropic") }
      end

      it "sets ONE system cache breakpoint when caching is on and provider is Anthropic" do
        c = anthropic_chat
        builder.configure_chat(c, state(system: "SOUL", prompt_caching: true))
        raw = c.instructions
        expect(raw).to be_a(RubyLLM::Content::Raw)
        block = raw.value.first
        expect(block[:text]).to eq("SOUL")
        expect(block[:cache_control]).to eq(type: "ephemeral")
      end

      it "uses a plain string when caching is on but the provider is NOT Anthropic" do
        c = FakeChat.new.tap { |ch| ch.model = Struct.new(:provider).new("openai") }
        builder.configure_chat(c, state(system: "SOUL", prompt_caching: true))
        expect(c.instructions).to eq("SOUL")
      end

      it "uses a plain string when caching is off, even on Anthropic (parity default)" do
        c = anthropic_chat
        builder.configure_chat(c, state(system: "SOUL", prompt_caching: nil))
        expect(c.instructions).to eq("SOUL")
      end

      it "stays off (plain string) when there is no resolved model" do
        builder.configure_chat(chat, state(system: "SOUL", prompt_caching: true)) # FakeChat#model is nil
        expect(chat.instructions).to eq("SOUL")
      end
    end

    it "uses the Resolution's tools (ready instances)" do
      t1 = Object.new
      t2 = Object.new
      builder.configure_chat(chat, state(allowed_tools: [t1, t2]))
      expect(chat.tools).to contain_exactly(t1, t2)
    end

    it "adds the system LoadSkill when there are allowed_skills" do
      builder.configure_chat(chat, state(allowed_tools: [Object.new], allowed_skills: ["cardapio"]))
      expect(chat.tools.size).to eq(2)
      expect(chat.tools.last).to be_a(Harness::Tools::LoadSkill)
    end

    it "doesn't add LoadSkill without skills" do
      builder.configure_chat(chat, state(allowed_tools: [Object.new], allowed_skills: []))
      expect(chat.tools.none? { |t| t.is_a?(Harness::Tools::LoadSkill) }).to be(true)
    end
  end

  describe "#configure_chat — Tool Search (eager/deferred partition)" do
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

    it "deferred leaves the eager wiring and the builtin ToolSearch enters" do
      st = ts_state(allowed_tools: [named_tool("send_email"), named_tool("other")],
                    tools_deferred: ["send_email"])
      builder_with_catalog.configure_chat(chat, st)

      names = chat.tools.map { |t| t.respond_to?(:name) ? t.name : nil }
      expect(names).to include("other")
      expect(names).not_to include("send_email") # deferred, not eager-wired
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(true)
    end

    it "ToolSearch is never wrapped (direct instance, like load_skill)" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      builder_with_catalog.configure_chat(chat, st)
      ts = chat.tools.find { |t| t.is_a?(Harness::Tools::ToolSearch) }
      expect(ts).not_to be_a(Harness::ToolEnvelope)
    end

    it "deferred_allowed = allowed ∩ tools_deferred (not the isolated tools_deferred)" do
      st = ts_state(allowed_tools: [named_tool("send_email")],
                    tools_deferred: %w[send_email ghost])
      builder_with_catalog.configure_chat(chat, st)
      ts = chat.tools.find { |t| t.is_a?(Harness::Tools::ToolSearch) }
      expect(ts.instance_variable_get(:@deferred_allowed)).to eq(["send_email"])
    end

    it "parity: without tool_catalog, all eager and no ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      builder.configure_chat(chat, st) # builder without tool_catalog
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(false)
    end

    it "profile.tools_deferred nil (with tool_catalog): all eager, no ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: nil)
      builder_with_catalog.configure_chat(chat, st)
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::ToolSearch) }).to be(false)
    end
  end

  describe "#configure_chat — system remember" do
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

    it "wires remember when @memory_store + profile.memory" do
      builder_with_memory.configure_chat(chat, mem_state(memory: true))
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::Remember) }).to be(true)
    end

    it "remember is never wrapped (direct instance)" do
      builder_with_memory.configure_chat(chat, mem_state(memory: true))
      rt = chat.tools.find { |t| t.is_a?(Harness::Tools::Remember) }
      expect(rt).not_to be_a(Harness::ToolEnvelope)
    end

    it "profile.memory nil: no remember (parity)" do
      builder_with_memory.configure_chat(chat, mem_state(memory: nil))
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::Remember) }).to be(false)
    end

    it "without @memory_store: no remember even with memory:true (parity)" do
      builder.configure_chat(chat, mem_state(memory: true)) # builder without memory_store
      expect(chat.tools.any? { |t| t.is_a?(Harness::Tools::Remember) }).to be(false)
    end
  end

  describe "#seed_history" do
    it "adds messages with role Symbol, in order, tolerating string keys" do
      builder.seed_history(chat, [
                             { role: :user, content: "oi" },
                             { "role" => "assistant", "content" => "olá" }
                           ])

      expect(chat.messages).to eq([
                                    { role: :user, content: "oi" },
                                    { role: :assistant, content: "olá" }
                                  ])
    end

    # §11 R1: fidelity between turns.
    it "rehydrates tool_calls (assistant) and tool_call_id (tool) only when present" do
      builder.seed_history(chat, [
                             { "role" => "assistant", "content" => "",
                               "tool_calls" => [{ "id" => "c1", "name" => "search",
                                                  "arguments" => { "q" => "x" } }] },
                             { "role" => "tool", "tool_call_id" => "c1", "content" => "res" }
                           ])

      assistant, tool = chat.messages
      expect(assistant[:tool_calls]).to be_a(Hash)
      tc = assistant[:tool_calls]["c1"]
      expect([tc.id, tc.name, tc.arguments]).to eq(["c1", "search", { "q" => "x" }])
      expect(tool[:tool_call_id]).to eq("c1")
      # the message without tool_calls does NOT get the key (keeps the fake's 2-arg shape)
      expect(assistant.key?(:tool_call_id)).to be(false)
    end

    it "flattens the provider's eviction units (Array) back into a flat flow" do
      builder.seed_history(chat, [
                             { role: :user, content: "u" },
                             [{ role: :assistant, content: "a" }, { role: :tool, content: "t", tool_call_id: "c1" }]
                           ])

      expect(chat.messages.map { |m| m[:role] }).to eq(%i[user assistant tool])
    end
  end

  describe "#wire_callbacks" do
    # The ChatBuilder emits via the injected callable; the seq+meta numbering is from
    # Executor#emit (covered in the pipeline specs). Here we record (type, data).
    def recording_emit(sink)
      ->(type, data) { sink << { type: type, data: data } }
    end

    it "emits :tool_call and :tool_result in order, with name and arguments" do
      sink = []
      builder.wire_callbacks(chat, state, recording_emit(sink))
      chat.fire_tool_call(name: "lookup", arguments: { "q" => "x" })
      chat.fire_tool_result("resultado")

      expect(sink.map { |e| e[:type] }).to eq(%i[tool_call tool_result])
      expect(sink.first[:data]).to eq({ name: "lookup", arguments: { "q" => "x" } })
      expect(sink.last[:data]).to eq({ name: "lookup", result: "resultado" })
    end

    it "emits :skill_activated (not :tool_call) for load_skill" do
      sink = []
      builder.wire_callbacks(chat, state, recording_emit(sink))
      chat.fire_tool_call(name: "load_skill", arguments: { "name" => "cardapio" })

      expect(sink.map { |e| e[:type] }).to eq([:skill_activated])
      expect(sink.first[:data]).to eq({ name: "cardapio" })
    end

    it "aborts with TimeoutError(stage: :tool_limit) when exceeding max_tool_calls" do
      builder.wire_callbacks(chat, state(limits: { max_tool_calls: 2 }), recording_emit([]))

      chat.fire_tool_call(name: "a")
      chat.fire_tool_call(name: "b")
      expect { chat.fire_tool_call(name: "c") }
        .to raise_error(Harness::TimeoutError) { |e| expect(e.stage).to eq(:tool_limit) }
    end

    it "uses the default of 50 when limits doesn't carry max_tool_calls" do
      builder.wire_callbacks(chat, state(limits: {}), recording_emit([]))

      50.times { |i| chat.fire_tool_call(name: "t#{i}") }
      expect { chat.fire_tool_call(name: "t50") }.to raise_error(Harness::TimeoutError)
    end
  end
end

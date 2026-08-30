# frozen_string_literal: true

require "spec_helper"
require "insika/tools/load_skill" # the Executor loads them lazily in create_chat; explicit here in the test
require "insika/tools/load_knowledge"
require "insika/tools/tool_search"
require "insika/tools/remember"
require "insika/tools/stuck_signal"
require "insika/tools/update_briefing"
require "insika/tools/schedule_followup"

RSpec.describe Insika::ChatBuilder do
  Ctx = Struct.new(:system)
  TaskStub = Struct.new(:id, :session_id)
  ProfileStub = Struct.new(:model, :provider, :limits, :prompt_caching, :skills_eager, :id)
  State = Struct.new(:context, :allowed_tools, :allowed_skills, :profile, :task,
                     :current_tool_call, :current_tool_name, keyword_init: true)

  let(:inert) { Object.new }
  let(:skill_catalog) { instance_double("Insika::SkillCatalog") }
  let(:event_stream) { Object.new }

  # Minimal ChatBuilder (inert deps except the ones the test exercises).
  def builder(tool_registry: inert, tool_catalog: nil, memory_store: nil, hooks: Insika::Hooks.new,
              session_store: nil)
    described_class.new(tool_registry: tool_registry, skill_catalog: skill_catalog,
                        checkpoint_store: inert, event_stream: event_stream, hooks: hooks,
                        tool_catalog: tool_catalog, memory_store: memory_store,
                        session_store: session_store)
  end

  let(:chat) { FakeChat.new }
  let(:task) { TaskStub.new("t", "s") }

  def state(system: "SOUL", allowed_tools: [], allowed_skills: [], limits: {}, prompt_caching: nil)
    State.new(context: Ctx.new(system), allowed_tools: allowed_tools,
              allowed_skills: allowed_skills,
              # `id` matters: load_skill resolves a specialized body per agent.
              profile: ProfileStub.new("gpt", nil, limits, prompt_caching, nil, "a"),
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

    context "prompt caching (R3)" do
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
      expect(chat.tools.last).to be_a(Insika::Tools::LoadSkill)
    end

    it "doesn't add LoadSkill without skills" do
      builder.configure_chat(chat, state(allowed_tools: [Object.new], allowed_skills: []))
      expect(chat.tools.none? { |t| t.is_a?(Insika::Tools::LoadSkill) }).to be(true)
    end

    # An eager skill is already in the prompt in full: there is no level 2 to fetch,
    # so it leaves the tool's allowlist. The catalog owns that verdict — the builder
    # asks, it does not re-derive it.
    describe "eager skills leave load_skill" do
      let(:eager_skill) { Struct.new(:name).new("formato") }

      it "serves only the lazy skills" do
        st = state(allowed_tools: [Object.new], allowed_skills: %w[formato cardapio])
        allow(skill_catalog).to receive(:eager_for).with(st.profile).and_return([eager_skill])

        builder.configure_chat(chat, st)

        tool = chat.tools.find { |t| t.is_a?(Insika::Tools::LoadSkill) }
        expect(tool).not_to be_nil
        expect(tool.execute(name: "formato")).to eq({ error: "skill 'formato' not available for this agent" })
      end

      it "is not wired at all when every allowed skill is eager" do
        st = state(allowed_tools: [Object.new], allowed_skills: ["formato"])
        allow(skill_catalog).to receive(:eager_for).with(st.profile).and_return([eager_skill])

        builder.configure_chat(chat, st)

        expect(chat.tools.none? { |t| t.is_a?(Insika::Tools::LoadSkill) }).to be(true)
      end
    end
  end

  describe "#configure_chat — Tool Search (eager/deferred partition)" do
    def named_tool(name)
      Class.new { define_method(:name) { name }; def description = "d" }.new
    end

    let(:tool_registry) do
      reg = Insika::ToolRegistry.new
      reg.register("send_email") { named_tool("send_email") }
      reg
    end
    let(:tool_catalog) { Insika::ToolCatalog.new(tool_registry: tool_registry) }

    def builder_with_catalog
      builder(tool_registry: tool_registry, tool_catalog: tool_catalog)
    end

    def ts_state(allowed_tools:, tools_deferred:)
      profile = Insika::AgentProfile.build(id: "a", model: "gpt", tools_deferred: tools_deferred)
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
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::ToolSearch) }).to be(true)
    end

    it "ToolSearch is never wrapped (direct instance, like load_skill)" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      builder_with_catalog.configure_chat(chat, st)
      ts = chat.tools.find { |t| t.is_a?(Insika::Tools::ToolSearch) }
      expect(ts).not_to be_a(Insika::ToolEnvelope)
    end

    it "deferred_allowed = allowed ∩ tools_deferred (not the isolated tools_deferred)" do
      st = ts_state(allowed_tools: [named_tool("send_email")],
                    tools_deferred: %w[send_email ghost])
      builder_with_catalog.configure_chat(chat, st)
      ts = chat.tools.find { |t| t.is_a?(Insika::Tools::ToolSearch) }
      expect(ts.instance_variable_get(:@deferred_allowed)).to eq(["send_email"])
    end

    it "parity: without tool_catalog, all eager and no ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: ["send_email"])
      builder.configure_chat(chat, st) # builder without tool_catalog
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::ToolSearch) }).to be(false)
    end

    it "profile.tools_deferred nil (with tool_catalog): all eager, no ToolSearch" do
      st = ts_state(allowed_tools: [named_tool("send_email")], tools_deferred: nil)
      builder_with_catalog.configure_chat(chat, st)
      expect(chat.tools.map(&:name)).to include("send_email")
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::ToolSearch) }).to be(false)
    end
  end

  describe "#configure_chat — system remember" do
    let(:mem) { Insika::MemoryStore.new(store: Insika::Stores::Memory.new) }

    def builder_with_memory
      builder(memory_store: mem)
    end

    def mem_state(memory:)
      profile = Insika::AgentProfile.build(id: "a", model: "gpt", memory: memory)
      st = Insika::TurnState.new(task: TaskStub.new("t", "s"), profile: profile, turn: 1, message: "oi")
      st.context = Ctx.new("SOUL")
      st.allowed_tools = []
      st.allowed_skills = []
      st.tenant = "acme"
      st
    end

    it "wires remember when @memory_store + profile.memory" do
      builder_with_memory.configure_chat(chat, mem_state(memory: true))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::Remember) }).to be(true)
    end

    it "remember is never wrapped (direct instance)" do
      builder_with_memory.configure_chat(chat, mem_state(memory: true))
      rt = chat.tools.find { |t| t.is_a?(Insika::Tools::Remember) }
      expect(rt).not_to be_a(Insika::ToolEnvelope)
    end

    it "profile.memory nil: no remember (parity)" do
      builder_with_memory.configure_chat(chat, mem_state(memory: nil))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::Remember) }).to be(false)
    end

    it "without @memory_store: no remember even with memory:true (parity)" do
      builder.configure_chat(chat, mem_state(memory: true)) # builder without memory_store
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::Remember) }).to be(false)
    end
  end

  describe "#configure_chat — system load_knowledge" do
    let(:kstore) { Insika::KnowledgeStore.new(store: Insika::Stores::Memory.new) }

    def builder_with_knowledge
      described_class.new(tool_registry: inert, skill_catalog: skill_catalog,
                          checkpoint_store: inert, event_stream: event_stream, hooks: Insika::Hooks.new,
                          knowledge_store: kstore)
    end

    def knowledge_state(knowledge:)
      profile = Insika::AgentProfile.build(id: "a", model: "gpt", knowledge: knowledge)
      st = Insika::TurnState.new(task: TaskStub.new("t", "s"), profile: profile, turn: 1, message: "oi")
      st.context = Ctx.new("SOUL")
      st.allowed_tools = []
      st.allowed_skills = []
      st.tenant = "acme"
      st
    end

    it "wires load_knowledge when @knowledge_store + profile.knowledge['retrieve']" do
      builder_with_knowledge.configure_chat(chat, knowledge_state(knowledge: { "retrieve" => true }))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::LoadKnowledge) }).to be(true)
    end

    it "load_knowledge is never wrapped (direct instance)" do
      builder_with_knowledge.configure_chat(chat, knowledge_state(knowledge: { "retrieve" => true }))
      lt = chat.tools.find { |t| t.is_a?(Insika::Tools::LoadKnowledge) }
      expect(lt).not_to be_a(Insika::ToolEnvelope)
    end

    it "profile.knowledge without retrieve: no load_knowledge (parity)" do
      builder_with_knowledge.configure_chat(chat, knowledge_state(knowledge: { "extract" => true }))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::LoadKnowledge) }).to be(false)
    end

    it "profile.knowledge nil: no load_knowledge (parity)" do
      builder_with_knowledge.configure_chat(chat, knowledge_state(knowledge: nil))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::LoadKnowledge) }).to be(false)
    end

    it "without @knowledge_store: no load_knowledge even with retrieve:true (parity)" do
      builder.configure_chat(chat, knowledge_state(knowledge: { "retrieve" => true })) # builder without knowledge_store
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::LoadKnowledge) }).to be(false)
    end
  end

  describe "#configure_chat — system signal_stuck (WS5)" do
    def stuck_state(on:)
      profile = Insika::AgentProfile.build(id: "a", model: "gpt", stuck_signal: on)
      st = Insika::TurnState.new(task: TaskStub.new("t", "s"), profile: profile, turn: 1, message: "oi")
      st.context = Ctx.new("SOUL")
      st.allowed_tools = []
      st.allowed_skills = []
      st
    end

    it "wires signal_stuck when profile.stuck_signal" do
      builder.configure_chat(chat, stuck_state(on: true))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::StuckSignal) }).to be(true)
    end

    it "signal_stuck is never wrapped (direct instance)" do
      builder.configure_chat(chat, stuck_state(on: true))
      st = chat.tools.find { |t| t.is_a?(Insika::Tools::StuckSignal) }
      expect(st).not_to be_a(Insika::ToolEnvelope)
    end

    it "profile.stuck_signal nil: no signal_stuck (parity)" do
      builder.configure_chat(chat, stuck_state(on: nil))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::StuckSignal) }).to be(false)
    end
  end

  describe "#configure_chat — the follow-up system tools " do
    let(:contact_store) { Insika::ContactStore.new(store: Insika::Stores::Memory.new) }
    let(:followup_store) { Insika::FollowupStore.new(store: Insika::Stores::Memory.new) }

    def followup_builder
      described_class.new(tool_registry: inert, skill_catalog: skill_catalog,
                          checkpoint_store: inert, event_stream: event_stream,
                          hooks: Insika::Hooks.new,
                          contact_store: contact_store, followup_store: followup_store)
    end

    def followup_state(declared: true)
      profile = Insika::AgentProfile.build(
        id: "a", model: "gpt",
        followup: declared ? { "arm" => "schedule", "policy" => {} } : nil
      )
      st = Insika::TurnState.new(task: TaskStub.new("t", "s"), profile: profile, turn: 1, message: "oi")
      st.context = Ctx.new("SOUL")
      st.allowed_tools = []
      st.allowed_skills = []
      st
    end

    it "wires schedule + cancel_followup when BOTH stores and a parsed policy are present" do
      followup_builder.configure_chat(chat, followup_state)
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::ScheduleFollowup) }).to be(true)
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::CancelFollowup) }).to be(true)
    end

    it "no profile declaration: neither tool (parity)" do
      followup_builder.configure_chat(chat, followup_state(declared: false))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::ScheduleFollowup) }).to be(false)
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::CancelFollowup) }).to be(false)
    end

    it "without the stores: neither tool even with a declaration (parity for unit stubs)" do
      builder.configure_chat(chat, followup_state)
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::ScheduleFollowup) }).to be(false)
    end
  end

  describe "#configure_chat — system briefing tools " do
    let(:sessions) { Insika::SessionStore.new(store: Insika::Stores::Memory.new) }

    def builder_with_sessions
      builder(session_store: sessions)
    end

    def briefing_state(fields:)
      profile = Insika::AgentProfile.build(id: "a", model: "gpt", briefing_fields: fields)
      st = Insika::TurnState.new(task: TaskStub.new("t", "s"), profile: profile, turn: 1, message: "oi")
      st.context = Ctx.new("SOUL")
      st.allowed_tools = []
      st.allowed_skills = []
      st
    end

    it "wires update_briefing + set_next_step when session_store present AND fields declared (double gate)" do
      builder_with_sessions.configure_chat(chat, briefing_state(fields: %w[size budget]))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::UpdateBriefing) }).to be(true)
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::UpdateBriefing::SetNextStep) }).to be(true)
    end

    it "neither wired when fields empty (parity — the feature is visibly off)" do
      builder_with_sessions.configure_chat(chat, briefing_state(fields: []))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::UpdateBriefing) }).to be(false)
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::UpdateBriefing::SetNextStep) }).to be(false)
    end

    it "without @session_store: no briefing tools even with fields (parity for unit stubs)" do
      builder.configure_chat(chat, briefing_state(fields: %w[size]))
      expect(chat.tools.any? { |t| t.is_a?(Insika::Tools::UpdateBriefing) }).to be(false)
    end

    it "briefing tools are never wrapped (direct instances)" do
      builder_with_sessions.configure_chat(chat, briefing_state(fields: %w[size]))
      t = chat.tools.find { |x| x.is_a?(Insika::Tools::UpdateBriefing) }
      expect(t).not_to be_a(Insika::ToolEnvelope)
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

    # R1: fidelity between turns.
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

    # The:tool_result label used to be a closure local shared by
    # the whole TURN, so with `ToolConcurrency` (one fiber per call, callbacks
    # included) `after_tool_result` labelled every result with whichever call
    # STARTED last. Mislabelled events poison the Studio trace, /v1/events and the
    # OTel tool spans — silently, since the payload still looks well-formed.
    it "labels each :tool_result with ITS OWN call, with two calls in flight" do
      require "async"
      sink = []
      # A REAL TurnState: the correlation is fiber-scoped inside it, which is the
      # thing under test (the Struct stub above would hide it behind a plain slot).
      real_state = Insika::TurnState.new(
        task: TaskStub.new("t", "s"), turn: 1, message: "hi",
        profile: ProfileStub.new("m", nil, {}, nil)
      )
      builder.wire_callbacks(chat, real_state, recording_emit(sink))

      Sync do |task|
        [["slow_tool", 0.05], ["fast_tool", 0.01]].map do |name, settle|
          task.async do
            chat.fire_tool_call(name: name, arguments: {})
            task.sleep(settle) # the provider round-trip / the tool's own IO
            chat.fire_tool_result("#{name} result")
          end
        end.each(&:wait)
      end

      labels = sink.select { |e| e[:type] == :tool_result }
                   .to_h { |e| [e[:data][:result], e[:data][:name]] }
      expect(labels).to eq("fast_tool result" => "fast_tool", "slow_tool result" => "slow_tool")
    end

    it "emits :skill_activated (not :tool_call) for load_skill" do
      sink = []
      builder.wire_callbacks(chat, state, recording_emit(sink))
      chat.fire_tool_call(name: "load_skill", arguments: { "name" => "cardapio" })

      expect(sink.map { |e| e[:type] }).to eq([:skill_activated])
      expect(sink.first[:data]).to eq({ name: "cardapio" })
    end

    it "emits :knowledge_retrieved (not :tool_call) for load_knowledge" do
      sink = []
      builder.wire_callbacks(chat, state, recording_emit(sink))
      chat.fire_tool_call(name: "load_knowledge", arguments: { "name" => "cep-13-campinas" })

      expect(sink.map { |e| e[:type] }).to eq([:knowledge_retrieved])
      expect(sink.first[:data]).to eq({ name: "cep-13-campinas", agent: "a" })
    end

    it "aborts with TimeoutError(stage: :tool_limit) when exceeding max_tool_calls" do
      builder.wire_callbacks(chat, state(limits: { max_tool_calls: 2 }), recording_emit([]))

      chat.fire_tool_call(name: "a")
      chat.fire_tool_call(name: "b")
      expect { chat.fire_tool_call(name: "c") }
        .to raise_error(Insika::TimeoutError) { |e| expect(e.stage).to eq(:tool_limit) }
    end

    it "uses the default of 50 when limits doesn't carry max_tool_calls" do
      builder.wire_callbacks(chat, state(limits: {}), recording_emit([]))

      50.times { |i| chat.fire_tool_call(name: "t#{i}") }
      expect { chat.fire_tool_call(name: "t50") }.to raise_error(Insika::TimeoutError)
    end

    # TurnBudget is unit-tested in turn_budget_spec; here only the wiring:
    # wire_callbacks must deliver the gem's three callbacks to it, so the model
    # is told the budget is running out instead of only meeting the abort.
    it "announces the tool budget at the batch boundary before the ceiling kills the turn" do
      sink = []
      builder.wire_callbacks(chat, state(limits: { max_tool_calls: 3, max_tool_repeat: 0 }),
                             recording_emit(sink))

      chat.fire_tool_call(name: "lookup", arguments: { "q" => "x" })
      chat.fire_tool_result_message("ok")

      notices = chat.messages.select { |m| m[:role] == :user }
      expect(notices.size).to eq(1)
      expect(notices.first[:content]).to include("2 tool calls left", "do not start new work")
      expect(sink.map { |e| e[:type] }).to include(:tool_budget_warned)
    end

    # the detector is unit-tested in loop_detector_spec; here only the
    # wiring: wire_callbacks must deliver the gem's three callbacks to it.
    it "intervenes once, then aborts the stubborn repeat as :tool_limit" do
      sink = []
      builder.wire_callbacks(chat, state(limits: { max_tool_repeat: 2 }), recording_emit(sink))

      2.times do
        chat.fire_tool_call(name: "lookup", arguments: { "q" => "x" })
        chat.fire_tool_result_message("same")
      end

      warnings = chat.messages.select { |m| m[:role] == :user }
      expect(warnings.size).to eq(1)
      expect(warnings.first[:content]).to include("lookup")
      expect(sink.map { |e| e[:type] }).to include(:tool_loop_intervened)

      expect { chat.fire_tool_call(name: "lookup", arguments: { "q" => "x" }) }
        .to raise_error(Insika::TimeoutError) { |e| expect(e.stage).to eq(:tool_limit) }
    end

    it "max_tool_repeat < 2 turns the detector off (max_tool_calls still bounds)" do
      builder.wire_callbacks(chat, state(limits: { max_tool_repeat: 0 }), recording_emit([]))

      4.times do
        chat.fire_tool_call(name: "lookup", arguments: { "q" => "x" })
        chat.fire_tool_result_message("same")
      end

      expect(chat.messages.select { |m| m[:role] == :user }).to be_empty
    end
  end
end

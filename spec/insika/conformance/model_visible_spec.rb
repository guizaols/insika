# frozen_string_literal: true

require "spec_helper"
require "async"
require "tmpdir"
require "fileutils"

# The harness stubs create_chat, so the lazy tool requires THAT method would
# do never run — preload the builtins the ChatBuilder may wire (memory, skills).
require_relative "../../../lib/insika/tools/load_skill"
require_relative "../../../lib/insika/tools/tool_search"
require_relative "../../../lib/insika/tools/remember"
require_relative "../../../lib/insika/tools/update_briefing"

# RFC-0036 C5/E3 — the conformance suite: "every byte that reaches the provider
# is reconstructable from checkpoints + traces". One oracle (the capturing
# chat), one assertion shape, the RFC's path list — context providers, tool
# cycles, steer appends, scheduled synthetic turns, subagent calls and the WS4
# routing ask. Workflows are OUT: a workflow orchestrates RubyLLM inside the
# workflow body, the engine cannot see those calls (stated, not waived).
#
# The suite drives the ORDINARY pipeline with the house harness (CapturingChat
# as the oracle) — no RubyLLM, no network, no keys (load-guard safe).
# A failing assertion names the path whose bytes are not logged: per the RFC,
# the FIX is engine-side, never a waiver — this suite has no skip mechanism.
RSpec.describe "the model-visible conformance suite (RFC-0036 C5)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:memory_store) { Insika::MemoryStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }
  let(:trace_store) { Insika::ModelVisibleTraceStore.new(store: backend) }
  let(:profile) { Insika::AgentProfile.build(id: "conformance", model: "gpt", base_prompt: "SOUL") }

  def build_executor(context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
                     profiles: nil, **over)
    Insika::Executor.new(
      context_builder: context_builder, policy_engine: policy_engine,
      middleware: Insika::MiddlewareStack.new([guardrails.input_guardrail]),
      hooks: Insika::Hooks.new, tool_registry: FakeToolRegistry.new,
      skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles || {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      memory_store: memory_store, content_filter_factory: guardrails.content_filter_factory,
      model_visible_trace_store: trace_store, **over
    )
  end

  def make_task(message, id: "t1", agent: "conformance", session_id: "s1", origin: nil)
    payload = { agent: agent, message: message }
    payload[:origin] = origin if origin
    command = Insika::Command.build(:send_message, payload)
    task_store.create(command: command.to_h, session_id: session_id, id: id)
  end

  def run_turn(executor, task, chat, run_profile: profile)
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      executor.spawn(task, profile: run_profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  # The reader with ONLY the two stores: instructions + schemas from the trace,
  # the message stream from the checkpoint transcript. The ONE bookkeeping byte
  # stripped: MessageOrigin's `origin` stamp — session bookkeeping the provider
  # never serializes (the transcript keeps it for the operator; the wire never
  # had it). Anything ELSE a path needs is the RFC's "gap becomes a fix" — the
  # fix lands in the engine, never in this helper.
  def reconstruct(trace, checkpoint)
    messages = checkpoint.messages.map { |m| m.reject { |k, _| k == "origin" } }
    Insika::ModelVisible.new(instructions: trace.instructions, tools: trace.tools, messages: messages)
  end

  # The one assertion shape: what the provider received == what the trace and
  # the checkpoint hold, byte for byte.
  def assert_conformance(task, chat)
    cp = checkpoint_store.latest(task.id)
    trace = trace_store.find(task.id, turn: cp.turn)
    expect(trace).not_to be_nil, "no model-visible trace for task #{task.id} turn #{cp.turn}"
    oracle = Insika::ModelVisible.capture(chat)

    expect(trace.instructions).to eq(oracle.instructions), "system text not logged"
    expect(trace.tools).to eq(oracle.tools), "tool schemas not logged"
    expect(trace.messages).to eq(cp.messages), "transcript identity broken (chat vs checkpoint)"
    expect(reconstruct(trace, cp).to_h).to eq(oracle.to_h), "payload not reconstructable from the two stores"
  end

  before { session_store.create(id: "s1") }

  # A minimal data tool for the chat (the pipeline wraps fakes untouched).
  DataTool = Struct.new(:name, :description, :parameters) do
    def call(_args) = { "found" => "TNSR1234" }
  end

  describe "P1 — context providers (the prompt-assembly half)" do
    def write_skill(dir, name, description:, triggers:, body:)
      FileUtils.mkdir_p(File.join(dir, name))
      frontmatter = +"name: #{name}\ndescription: #{description}\ntriggers:\n"
      triggers.each { |t| frontmatter << "  - #{t}\n" }
      File.write(File.join(dir, name, "SKILL.md"), "---\n#{frontmatter}---\n#{body}\n")
    end

    def build_context
      Dir.mktmpdir do |dir|
        write_skill(dir, "eager-one", description: "Eager procedure", triggers: [], body: "1. Measure. 2. Act.")
        write_skill(dir, "lazy-one", description: "Lazy reference", triggers: ["presente"], body: "The lazy procedure.")

        catalog = Insika::SkillCatalog.new([dir])
        builder = Insika::ContextBuilder.new(
          providers: [
            Insika::Context::Providers::Request.new,
            Insika::Context::Providers::Prompt.new(base: "SOUL"),
            Insika::Context::Providers::Skill.new(catalog: catalog),
            Insika::Context::Providers::SkillTrigger.new(catalog: catalog),
            Insika::Context::Providers::Memory.new(store: memory_store),
            Insika::Context::Providers::Session.new(session_store: session_store)
          ],
          event_stream: event_stream, hooks: Insika::Hooks.new
        )
        return [builder, catalog]
      end
    end

    let(:context) { build_context }
    let(:builder) { context[0] }

    let(:rich_profile) do
      Insika::AgentProfile.build(
        id: "conformance", model: "gpt",
        prompt_files: ["base"], memory: true,
        skills: ["eager-one", "lazy-one"], skills_eager: ["eager-one"]
      )
    end

    it "the eager body, lazy table, memory block and request label all reach the system text — and the trace" do
      memory_store.put_fact(tenant: "chat:s1", key: "size", value: "M")
      session_store.update_vars("s1", "channel" => "relay") # Request provider label

      executor = build_executor(context_builder: builder)
      chat = CapturingChat.new
      chat.final_content = "entendi."

      task = make_task("oi")
      run_turn(executor, task, chat, run_profile: rich_profile)

      cp = checkpoint_store.latest(task.id)
      trace = trace_store.find(task.id, turn: cp.turn)
      system = trace.instructions.to_s
      expect(system).to include("SOUL")                              # the base prompt
      expect(system).to include("Measure. 2. Act.")                  # the eager body (SkillTrigger)
      expect(system).to include("lazy-one")                          # the lazy table (Skill)
      expect(system).to include('<fact key="size">M</fact>')         # the memory block (Memory)
      expect(system).to include("<request_context>").and include("channel: relay") # Request

      assert_conformance(task, chat)
    end

    it "turn 2 replays the turn-1 transcript through the seeded history — still byte-identical" do
      executor = build_executor(context_builder: builder)
      run_turn(executor, make_task("oi", id: "t1"), CapturingChat.new, run_profile: rich_profile)

      chat2 = CapturingChat.new
      chat2.final_content = "respondido de novo."
      run_turn(executor, make_task("oi de novo", id: "t2"), chat2, run_profile: rich_profile)

      cp = checkpoint_store.latest("t2")
      trace = trace_store.find("t2", turn: cp.turn)
      oracle = Insika::ModelVisible.capture(chat2)

      # the seeded history occupies the pre-baseline slice — the trace carries it
      # byte-for-byte and the reader rebuilds the full provider stream
      expect(trace.messages).to eq(cp.messages)
      expect(reconstruct(trace, cp).to_h).to eq(oracle.to_h)
      expect(trace.messages.length).to be > 2 # history + this turn
    end
  end

  describe "P2 — a full tool-call + result cycle" do
    it "the tool schemas are logged; the result bytes survive in messages == transcript" do
      tool = DataTool.new("search_products", "search the catalog",
                          { "type" => "object", "properties" => { "q" => { "type" => "string" } } })
      executor = build_executor(policy_engine: NullPolicyEngine.new(allowed_tools: [tool]))
      chat = CapturingChat.new
      chat.script = proc do
        fire_tool_call(name: "search_products", arguments: { "q" => "tenis" })
        result = @tools.first.call({})
        fire_tool_result(result)
        fire_tool_result_message(result)
        emit_chunk("Achei o produto 1234.")
      end
      chat.final_content = "Achei o produto 1234."

      task = make_task("quero um tenis")
      run_turn(executor, task, chat)

      cp = checkpoint_store.latest(task.id)
      trace = trace_store.find(task.id, turn: cp.turn)
      expect(trace.tools.length).to eq(1)
      expect(trace.tools.first["name"]).to eq("search_products")
      expect(trace.tools.first["parameters"]["properties"]).to eq("q" => { "type" => "string" })

      assert_conformance(task, chat)
    end
  end

  describe "P3 — a steered message lands at the batch boundary, byte-equal everywhere" do
    it "the steered text appears in oracle, checkpoint and trace" do
      tool = DataTool.new("lookup", "find", { "type" => "object", "properties" => {} })
      executor = build_executor(policy_engine: NullPolicyEngine.new(allowed_tools: [tool]))
      chat = CapturingChat.new
      chat.script = proc do
        fire_tool_call(name: "lookup", arguments: {})
        @tools.first.call({})
        fire_tool_result("result B")
        fire_tool_result_message("result B")
        # the engine's steer append at the batch boundary (SteerInjector#inject!
        # does exactly this: chat.add_message(role: :user, content: framed text))
        add_message(role: :user, content: "1234567")
        emit_chunk("segure o número.")
      end
      chat.final_content = "segure o número."

      task = make_task("qual é")
      run_turn(executor, task, chat)

      cp = checkpoint_store.latest(task.id)
      trace = trace_store.find(task.id, turn: cp.turn)
      oracle = Insika::ModelVisible.capture(chat)

      expect(oracle.messages.map { |m| m["content"] }).to include("1234567")
      expect(cp.messages.map { |m| m["content"] }).to include("1234567")
      expect(trace.messages.map { |m| m["content"] }).to include("1234567")
      assert_conformance(task, chat)
    end
  end

  describe "P4 — a subagent runs as its OWN task with its OWN trace" do
    let(:child_profile) { Insika::AgentProfile.build(id: "child", model: "gpt", base_prompt: "CHILD-SOUL") }
    let(:parent_profile) do
      Insika::AgentProfile.build(id: "conformance", model: "gpt", base_prompt: "SOUL",
                                 subagents: ["child"])
    end

    def parent_state
      cmd = Insika::Command.build(:send_message, { agent: "conformance", message: "go" }).to_h
      task = task_store.create(command: cmd, session_id: "s1", id: "parent-task")
      st = Insika::TurnState.new(task: task, profile: parent_profile, turn: 1, message: "go")
      st.turn_context = { delegation_depth: 0 }
      st
    end

    it "the child's checkpoint + trace reconstruct its provider payload (its own bytes)" do
      profiles = Insika::StoredProfileSource.new(config_store: Insika::ConfigStore.new(store: backend))
      profiles.put(child_profile)
      profiles.put(parent_profile)
      executor = build_executor(profiles: profiles)

      child_chat = CapturingChat.new
      child_chat.final_content = "resumo do subagente"
      allow(executor).to receive(:create_chat).and_return(child_chat)

      result = nil
      Sync { result = executor.run_subagent(agent: "child", message: "resuma isto", parent_state: parent_state) }
      expect(result[:text]).to eq("resumo do subagente")

      # the child is its OWN task — find it and reconstruct ITS payload
      child_task_id = task_store.each_id.to_a.find { |id| id != "parent-task" }
      child_task = task_store.find(child_task_id)
      cp = checkpoint_store.latest(child_task_id)
      trace = trace_store.find(child_task_id, turn: cp.turn)

      expect(child_task).not_to be_nil
      expect(trace).not_to be_nil
      expect(trace.instructions).to include("CHILD-SOUL")
      expect(trace.instructions).to eq(Insika::ModelVisible.capture(child_chat).instructions)
      expect(trace.messages).to eq(cp.messages) # the child's transcript identity holds too
    end
  end

  describe "P5 — a scheduled (engine-origin) turn" do
    it "the origin-marked message is in the transcript; reconstruction holds" do
      executor = build_executor
      chat = CapturingChat.new
      chat.final_content = "Voltei, como combinado."

      run_turn(executor, make_task("te chamo amanhã", id: "t1", origin: "engine"), chat)

      cp = checkpoint_store.latest("t1")
      trace = trace_store.find("t1", turn: cp.turn)

      # P5's byte: the transcript stamps who WROTE the message...
      expect(cp.messages.first["origin"]).to eq("engine")
      expect(trace.messages).not_to eq(cp.messages) # ...and the provider never sees it
      # ...which is exactly the ONE bookkeeping key reconstruct strips: the
      # payload rebuilds from the two stores alone
      expect(reconstruct(trace, cp).to_h).to eq(Insika::ModelVisible.capture(chat).to_h)
    end
  end

  describe "P6 — the WS4 routing classifier is a model-visible ask" do
    it "part 'routing' holds the classifier; part 'turn' holds the answer ask" do
      routed = Insika::AgentProfile.build(id: "conformance", model: "gpt", base_prompt: "SOUL",
                                          routes: { "shopping" => "the customer wants to shop",
                                                    "default" => "shopping", "model" => "cheap" })

      classifier = CapturingChat.new
      classifier.final_content = "shopping"
      answer = CapturingChat.new
      answer.final_content = "pode ser."

      llm = double("llm")
      allow(llm).to receive(:chat).and_return(classifier)

      executor = build_executor(llm: llm)
      task = make_task("quero comprar")
      run_turn(executor, task, answer, run_profile: routed) # create_chat -> answer; route_ask -> llm.chat -> classifier

      cp = checkpoint_store.latest(task.id)
      routing = trace_store.find(task.id, turn: cp.turn, part: "routing")
      turn = trace_store.find(task.id, turn: cp.turn)
      expect(routing).not_to be_nil
      expect(turn).not_to be_nil

      # the classifier's OWN payload is reconstructable from its part record
      expect(routing.instructions.to_s).to include("shopping") # the generated classifier prompt
      expect(routing.messages.map { |m| m["content"] }).to include("quero comprar")
      expect(routing.instructions).to eq(Insika::ModelVisible.capture(classifier).instructions)

      # the answer ask is the ordinary turn record
      assert_conformance(task, answer)
    end
  end

  describe "the seam's parity (RFC-0036 C4)" do
    it "nil store = the turn behaves byte-identically (the default executor)" do
      executor = build_executor(model_visible_trace_store: nil)
      chat = CapturingChat.new
      chat.final_content = "sem trace."

      run_turn(executor, make_task("oi", id: "parity"), chat)

      expect(task_store.find("parity").status).to eq(:completed)
      expect(chat.asked).to eq("oi")
    end
  end

  describe "P7 — a resuming turn re-records its ask in place (the approval-resume shape)" do
    def seed_crashed(turn:)
      task = make_task("oi", id: "t1")
      task_store.begin_execution("t1")
      task_store.transition("t1", to: :running)
      cp = Insika::Checkpoint.new(task_id: "t1", turn: turn, session_id: "s1", agent_id: "conformance",
                                  messages: [{ "role" => "user", "content" => "oi" }],
                                  completed_side_effects: [], created_at: nil)
      checkpoint_store.save(cp)
      [task, cp]
    end

    def resume_turn(executor, task, cp, chat)
      allow(executor).to receive(:create_chat).and_return(chat)
      Sync do
        executor.spawn(task, profile: profile, resume_from: cp)
        executor.instance_variable_get(:@running)[task.id]&.wait
      end
    end

    it "the resumed ask re-records the same (task, turn) — one record, covering the resumed bytes" do
      executor = build_executor
      task, cp = seed_crashed(turn: 2) # the interrupted run left its checkpoint at turn 2

      # the interrupted run HAD completed its ask before the crash — a record at
      # turn 3 (R1: the provider-visible stream of turn 3 == checkpoint 3... the
      # first attempt died BEFORE persisting, so only the trace saw it).
      trace_store.record(task_id: "t1", turn: 3,
                         payload: Insika::ModelVisible.new(instructions: "OLD", tools: [], messages: []))

      resumed = CapturingChat.new
      resumed.final_content = "respondido após o resume."
      resume_turn(executor, task, cp, resumed)

      cp_final = checkpoint_store.latest("t1")
      # the resumed ask re-recorded AT the same turn — the UPSERT replaced the
      # interrupted attempt's bytes in place, never duplicated
      expect(trace_store.for_task("t1").length).to eq(1)
      trace = trace_store.find("t1", turn: cp_final.turn)
      expect(trace.instructions).to eq(Insika::ModelVisible.capture(resumed).instructions)
      assert_conformance(task, resumed)
    end
  end
end
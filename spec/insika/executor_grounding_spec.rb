# frozen_string_literal: true

require "spec_helper"
require "async"

# RFC-0029 E2 — the acceptance gate, end-to-end through the REAL Executor. A
# turn whose data tool returns an evidence-shaped result: the provider step sees
# the LEAN items, the ids land on the session evidence ledger, and the final
# answer claiming a non-ledgered id is, per mode, FLAGGED (`:flag` ->
# `:guardrail_flagged` with category "ungrounded") or CUT (`:enforce` -> the
# terminal content is the cut text).
RSpec.describe "Insika::Executor — grounding end-to-end (RFC-0029 E2)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }

  def matcher = { "sku" => '\b[A-Z]{2,4}\d{4,8}\b' }

  # A data-tool-shaped fake: returns the evidence_envelope body. It gets wrapped
  # by the real ToolEnvelope, which is what processes the evidence.
  class GroundingSearchTool
    def name = "search_products"
    def description = "Busca produtos"
    def evidence = { "kind" => "products" }

    def call(_args)
      { "__insika_body" => JSON.generate(
        "items" => [{ "id" => "TNSR1234", "line" => "Tênis Runner 42 — one line" }]
      ) }
    end
  end

  def build_executor(profile, hooks: NullHooks.new, grounding_enforcer: nil)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: NullPolicyEngine.new(allowed_tools: [GroundingSearchTool.new]),
      middleware: PassthroughMiddleware.new, hooks: hooks,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      grounding_enforcer: grounding_enforcer
    )
  end

  # after_task hook = the real OutputValidator (which runs the grounding
  # validator FIRST, before the output gate — D9).
  def flag_hooks
    h = Insika::Hooks.new
    h.register(:task, after: guardrails.output_validator)
    h
  end

  before { session_store.create(id: "s1") }

  def run_turn(executor, chat)
    allow(executor).to receive(:create_chat).and_return(chat)
    command = Insika::Command.build(:send_message, { agent: "store", message: "quero um tenis" })
    task_store.create(command: command.to_h, session_id: "s1", id: "t")
    Sync do
      executor.spawn(task_store.find("t"), profile: profile)
      executor.instance_variable_get(:@running)["t"]&.wait
    end
  end

  describe "the lean envelope in the real pipeline" do
    let(:profile) { Insika::AgentProfile.build(id: "store", model: "gpt", base_prompt: "SOUL",
                                               grounding: { "mode" => "off", "matcher" => matcher }) }

    it "the provider step sees the LEAN items (never the raw body), and the session holds the evidence" do
      seen = nil
      chat = FakeChat.new
      chat.script = proc do
        tool = tools.find { |t| t.respond_to?(:evidence) }
        seen = tool.call({})
        emit_chunk("O TNSR1234 chegou hoje.")
      end
      chat.final_content = "O TNSR1234 chegou hoje."

      run_turn(build_executor(profile), chat)

      expect(seen).to eq("items" => [{ "id" => "TNSR1234", "line" => "Tênis Runner 42 — one line" }])
      expect(seen.to_s).not_to include("__insika_body")
      expect(session_store.find("s1").evidence["ids"]).to eq(["TNSR1234"])
    end

    it "E1 (engine half): the persisted transcript carries ONLY the lean result, not the raw body" do
      chat = FakeChat.new
      chat.script = proc do
        tools.find { |t| t.respond_to?(:evidence) }.call({})
        emit_chunk("O TNSR1234 chegou hoje.")
      end
      chat.final_content = "O TNSR1234 chegou hoje."

      run_turn(build_executor(profile), chat)

      raw_body = JSON.generate("items" => [{ "id" => "TNSR1234", "line" => "Tênis Runner 42 — one line" }])
      transcript = session_store.find("s1").messages.map { |m| (m["content"] || m[:content]).to_s }.join("\n")
      expect(transcript).to include("TNSR1234")
      expect(transcript).not_to include("__insika_body")

      # the lean result's tokens are a strict subset of the raw body's — the
      # replayed history stays lean by construction (E1's savings compound every
      # subsequent turn through the Session provider's replay).
      lean_tokens = Insika::TokenEstimator.estimate('"items":[{"id":"TNSR1234","line":"Tênis Runner 42 — one line"}]')
      expect(Insika::TokenEstimator.estimate(raw_body)).to be > lean_tokens
    end
  end

  describe "mode :flag" do
    let(:profile) { Insika::AgentProfile.build(id: "store", model: "gpt", base_prompt: "SOUL",
                                               grounding: { "mode" => "flag", "matcher" => matcher }) }

    it "a final answer naming an ABSENT SKU emits :guardrail_flagged (category ungrounded) and counts it" do
      chat = FakeChat.new
      chat.script = proc do
        tools.find { |t| t.respond_to?(:evidence) }.call({})
        emit_chunk("O modelo TNSR9999 está disponível.")
      end
      chat.final_content = "O modelo TNSR9999 está disponível."

      run_turn(build_executor(profile, hooks: flag_hooks), chat)

      flag = event_stream.events.find { |e| e.type == :guardrail_flagged }
      expect(flag).not_to be_nil
      expect(flag.data).to include(category: "ungrounded", source: "evidence")
      expect(flag.data[:detail]).to include("TNSR9999")

      session = session_store.find("s1")
      expect(session.evidence["ids"]).to eq(["TNSR1234"])
      expect(session.evidence["ungrounded"]).to eq(1)
    end

    it "a final answer naming a LEDGERED id is NOT flagged" do
      chat = FakeChat.new
      chat.script = proc do
        tools.find { |t| t.respond_to?(:evidence) }.call({})
        emit_chunk("O TNSR1234 chegou hoje.")
      end
      chat.final_content = "O TNSR1234 chegou hoje."

      run_turn(build_executor(profile, hooks: flag_hooks), chat)

      expect(event_stream.types).not_to include(:guardrail_flagged)
      expect(session_store.find("s1").evidence["ungrounded"]).to eq(0)
    end
  end

  describe "mode :enforce" do
    let(:profile) { Insika::AgentProfile.build(id: "store", model: "gpt", base_prompt: "SOUL",
                                               grounding: { "mode" => "enforce", "matcher" => matcher }) }

    it "the terminal content is the CUT text and the flag carries action: cut" do
      chat = FakeChat.new
      chat.script = proc do
        tools.find { |t| t.respond_to?(:evidence) }.call({})
        emit_chunk("O TNSR1234 chegou hoje. O modelo TNSR9999 também está em estoque.")
      end
      chat.final_content = "O TNSR1234 chegou hoje. O modelo TNSR9999 também está em estoque."

      run_turn(build_executor(profile, grounding_enforcer: guardrails.grounding_enforcer), chat)

      data = event_stream.events.find { |e| e.type == :task_completed }.data
      expect(data[:content]).to eq("O TNSR1234 chegou hoje.")

      flag = event_stream.events.find { |e| e.type == :guardrail_flagged }
      expect(flag.data).to include(category: "ungrounded", source: "evidence", action: "cut")

      session = session_store.find("s1")
      expect(session.evidence["ids"]).to eq(["TNSR1234"])
      expect(session.evidence["ungrounded"]).to eq(1)
    end

    it "an embedder that wires the Executor WITHOUT an explicit enforcer still gets the cut (default, not silent no-check)" do
      chat = FakeChat.new
      chat.script = proc do
        tools.find { |t| t.respond_to?(:evidence) }.call({})
        emit_chunk("O TNSR1234 chegou hoje. O modelo TNSR9999 também está em estoque.")
      end
      chat.final_content = "O TNSR1234 chegou hoje. O modelo TNSR9999 também está em estoque."

      run_turn(build_executor(profile), chat) # no grounding_enforcer kwarg

      data = event_stream.events.find { |e| e.type == :task_completed }.data
      expect(data[:content]).to eq("O TNSR1234 chegou hoje.")
      flag = event_stream.events.find { |e| e.type == :guardrail_flagged }
      expect(flag.data).to include(action: "cut")
    end
  end
end

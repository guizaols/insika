# frozen_string_literal: true

require "spec_helper"
require "async"

# Characterization of the ToolEnvelope hot path (R0): the branches
# the approval spec does NOT exercise — per-call timeout serialization, skip-on-resume,
# side-effect recording, and call correlation. LOCKS current behavior BEFORE R1
# (persisting tool calls/results) and the future R4 (parallel tools) touch it.
RSpec.describe Insika::ToolEnvelope do
  let(:backend) { Insika::Stores::Memory.new }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }

  # Tool fakes named to avoid collision with the approval spec's ChargeTool.
  # Each records its calls so we can assert (non-)execution.
  class EnvEchoTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "echo"
    def call(args) = (@calls << args) && "echoed"
  end

  # Sleeps on the reactor so ToolEnvelope's with_timeout can fire. A plain
  # Kernel#sleep would block the reactor and the timer would never run.
  class EnvSleepyTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "slow"

    def call(args)
      @calls << args
      Async::Task.current.sleep(1)
      "done"
    end
  end

  # Delegate exposing impl_name: the envelope must resolve side_effect?/correlation
  # against the REAL registered name, not a capability alias.
  class EnvAliasTool
    def name = "capability_alias"
    def impl_name = "real_tool"
    def call(_args) = "ran"
  end

  def state_for(task_id: "t", session_id: nil, turn: 1, current_tool_call: nil)
    profile = Insika::AgentProfile.build(id: "a", model: "m")
    task = Struct.new(:id, :session_id).new(task_id, session_id)
    st = Insika::TurnState.new(task: task, profile: profile, turn: turn, message: "oi")
    st.requires_approval = []
    st.current_tool_call = current_tool_call
    st
  end

  def envelope(tool, state, timeout: 60, skip_side_effects: [], tool_registry: FakeToolRegistry.new,
               trace_recorder: nil)
    described_class.new(tool, state: state, checkpoint_store: checkpoint_store,
                              tool_registry: tool_registry, timeout: timeout,
                              skip_side_effects: skip_side_effects, trace_recorder: trace_recorder)
  end

  describe "per-call timeout" do
    it "timeout fired -> returns a serialized error to the model, does NOT propagate (the turn continues)" do
      tool = EnvSleepyTool.new
      env = envelope(tool, state_for, timeout: 0.01)

      result = Sync { env.call({ "x" => 1 }) }

      expect(result).to eq({ error: "TimeoutError: tool exceeded 0.01s" })
      expect(tool.calls).to eq([{ "x" => 1 }]) # the tool WAS entered; it was interrupted midway
    end

    it "timeout does NOT record a side-effect (recorded only after a successful return)" do
      registry = FakeToolRegistry.new(side_effect_names: ["slow"])
      state = state_for(current_tool_call: Struct.new(:id).new("call-1"))
      env = envelope(EnvSleepyTool.new, state, timeout: 0.01, tool_registry: registry)

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to be_empty
    end

    it "timeout is traced with ok=false when there is a trace_recorder" do
      recorder = Insika::ToolTraceStore.new(store: backend)
      env = envelope(EnvSleepyTool.new, state_for(session_id: "s"), timeout: 0.01,
                                                                    trace_recorder: recorder)

      Sync { env.call({}) }

      trace = recorder.for_session("s")
      expect(trace.size).to eq(1)
      expect(trace.first).to include("ok" => false, "tool" => "slow")
      expect(trace.first["result"]).to include("TimeoutError")
    end
  end

  describe "skip-on-resume (side-effect already executed in the interrupted turn)" do
    it "call_id in skip_side_effects -> {skipped} marker, does NOT re-execute the tool" do
      tool = EnvEchoTool.new
      state = state_for(current_tool_call: Struct.new(:id).new("call-42"))
      env = envelope(tool, state, skip_side_effects: ["call-42"])

      result = Sync { env.call({ "amount" => 10 }) }

      expect(result).to eq({ "skipped" => "already_executed" })
      expect(tool.calls).to be_empty
    end

    it "call_id ABSENT from the skip set -> executes normally" do
      tool = EnvEchoTool.new
      state = state_for(current_tool_call: Struct.new(:id).new("call-99"))
      env = envelope(tool, state, skip_side_effects: ["outro-id"])

      result = Sync { env.call({}) }

      expect(result).to eq("echoed")
      expect(tool.calls.size).to eq(1)
    end

    it "correlation by NAME (workflow, no provider id): skip is per-tool, not per-call" do
      tool = EnvEchoTool.new # current_tool_call nil -> correlation_id falls back to the name "echo"
      env = envelope(tool, state_for, skip_side_effects: ["echo"])

      result = Sync { env.call({}) }

      expect(result).to eq({ "skipped" => "already_executed" })
      expect(tool.calls).to be_empty
    end
  end

  describe "record_side_effect! (records BEFORE the result returns to the model)" do
    it "tool marked as a side-effect -> records the correlation call_id in the checkpoint_store" do
      registry = FakeToolRegistry.new(side_effect_names: ["echo"])
      state = state_for(current_tool_call: Struct.new(:id).new("call-7"))
      env = envelope(EnvEchoTool.new, state, tool_registry: registry)

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["call-7"])
    end

    it "tool NOT marked -> records nothing" do
      state = state_for(current_tool_call: Struct.new(:id).new("call-7"))
      env = envelope(EnvEchoTool.new, state) # FakeToolRegistry without side_effect_names

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to be_empty
    end

    it "without current_tool_call, the side-effect is recorded by the tool's real NAME" do
      registry = FakeToolRegistry.new(side_effect_names: ["echo"])
      env = envelope(EnvEchoTool.new, state_for, tool_registry: registry)

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["echo"])
    end
  end

  describe "impl_name (capability alias)" do
    it "resolves side_effect?/correlation against the real impl_name, not the alias" do
      registry = FakeToolRegistry.new(side_effect_names: ["real_tool"])
      env = envelope(EnvAliasTool.new, state_for, tool_registry: registry)

      result = Sync { env.call({}) }

      expect(result).to eq("ran")
      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["real_tool"])
    end
  end

  describe "delegation (SimpleDelegator)" do
    it "delegates name/description to the real tool" do
      env = envelope(EnvEchoTool.new, state_for)
      expect(env.name).to eq("echo")
    end
  end

  #   — the evidence envelope: reshape the declared-evidence result,
  # record the ids on the ledger, hoard the attachments. No evidence = pass-through.
  describe "evidence envelope " do
    let(:session_store) { Insika::SessionStore.new(store: backend) }
    let(:ledger) { Insika::EvidenceLedger.new(store: session_store, session_id: "s1") }

    before { session_store.create(id: "s1") }

    def evidence_state
      state = state_for(session_id: "s1")
      state.evidence_ledger = ledger
      state
    end

    # A code tool declaring evidence via its `evidence` reader (D4, path 1).
    class EnvEvidenceTool
      def name = "search_products"
      def evidence = { "kind" => "products" }
      def call(_args)
        { "__insika_body" => JSON.generate(
          "items" => [{ "id" => "SKU-1", "line" => "Tênis Runner 42" }],
          "attachments" => [{ "type" => "card", "url" => "https://cdn/x.png", "caption" => "Tênis" }]
        ) }
      end
    end

    # A plain tool with NO evidence reader — must pass through byte-identical.
    class EnvPlainTool
      def name = "plain"
      def call(_args) = "plain result"
    end

    it "no evidence spec -> result passes through byte-identical, nothing recorded" do
      st = evidence_state
      env = envelope(EnvPlainTool.new, st)
      expect(Sync { env.call({}) }).to eq("plain result")
      expect(ledger.ids).to be_empty
      expect(st.evidence_attachments).to eq([])
    end

    it "declared evidence (tool reader path) -> lean {items} to the model, ids on the ledger, attachments hoarded" do
      st = evidence_state
      env = envelope(EnvEvidenceTool.new, st)
      result = Sync { env.call({}) }

      expect(result).to eq("items" => [{ "id" => "SKU-1", "line" => "Tênis Runner 42" }])
      expect(ledger.ids).to eq(["SKU-1"])
      expect(st.evidence_attachments)
        .to eq([{ "type" => "card", "url" => "https://cdn/x.png", "caption" => "Tênis" }])
    end

    it "declared evidence via the registry entry metadata (code-tool path, D4 path 2)" do
      registry = FakeToolRegistry.new(side_effect_names: [])
      def registry.entries = [Insika::Registry::Entry.new(
        name: "legacy_tool", plugin: "test", metadata: { evidence: { "kind" => "products" } },
        factory: -> {}
      )]
      tool = Class.new do
        def name = "legacy_tool"
        def call(_args) = { "items" => [{ "id" => "A", "line" => "x" }] }
      end.new
      env = envelope(tool, evidence_state, tool_registry: registry)

      result = Sync { env.call({}) }
      expect(result).to eq("items" => [{ "id" => "A", "line" => "x" }])
      expect(ledger.ids).to eq(["A"])
    end

    it "{error:} result is untouched and records nothing" do
      tool = Class.new do
        def name = "failing"
        def evidence = { "kind" => "products" }
        def call(_args) = { error: "backend said no" }
      end.new
      env = envelope(tool, evidence_state)
      expect(Sync { env.call({}) }).to eq({ error: "backend said no" })
      expect(ledger.ids).to be_empty
    end

    it "malformed items -> {error:} result and NO ledger record" do
      tool = Class.new do
        def name = "bad"
        def evidence = { "kind" => "products" }
        def call(_args) = { "__insika_body" => JSON.generate("items" => [{ "id" => "" }]) }
      end.new
      env = envelope(tool, evidence_state)
      result = Sync { env.call({}) }

      expect(result).to include(:error)
      expect(ledger.ids).to be_empty
    end

    it "a bare JSON array body (no object) -> {error:}, never a silent empty items" do
      tool = Class.new do
        def name = "array_body"
        def evidence = { "kind" => "products" }
        def call(_args) = { "__insika_body" => JSON.generate([{ "id" => "A" }]) }
      end.new
      env = envelope(tool, evidence_state)
      result = Sync { env.call({}) }

      expect(result[:error]).to eq("evidence: result must be an object")
      expect(ledger.ids).to be_empty
    end

    it "non-JSON __insika_body -> envelope error, nothing recorded (fail closed)" do
      tool = Class.new do
        def name = "garbage"
        def evidence = { "kind" => "products" }
        def call(_args) = { "__insika_body" => "{nope" }
      end.new
      env = envelope(tool, evidence_state)
      result = Sync { env.call({}) }

      expect(result[:error]).to match(/evidence processing failed/)
      expect(ledger.ids).to be_empty
    end

    it "caps items at MAX_ITEMS" do
      tool = Class.new do
        def name = "many"
        def evidence = { "kind" => "products" }
        def call(_args)
          items = (1..30).map { |i| { "id" => "SKU-#{i}", "line" => "produto #{i}" } }
          { "__insika_body" => JSON.generate("items" => items) }
        end
      end.new
      env = envelope(tool, evidence_state)
      result = Sync { env.call({}) }

      expect(result["items"].size).to eq(Insika::Evidence::MAX_ITEMS)
      expect(ledger.ids.size).to eq(Insika::Evidence::MAX_ITEMS)
    end

    it "the trace_recorder receives the LEAN result (never the raw body)" do
      recorder = Class.new do
        attr_reader :entries
        def initialize = (@entries = [])
        def record(session_id:, entry:) = @entries << entry
      end.new
      env = envelope(EnvEvidenceTool.new, evidence_state, trace_recorder: recorder)
      Sync { env.call({}) }

      expect(recorder.entries.size).to eq(1)
      expect(recorder.entries.first["result"]).to eq("items" => [{ "id" => "SKU-1", "line" => "Tênis Runner 42" }])
      expect(recorder.entries.first["result"].to_s).not_to include("__insika_body")
    end

    it "state without a ledger is fine (duck-typed no-op)" do
      env = envelope(EnvEvidenceTool.new, state_for)
      result = Sync { env.call({}) }
      expect(result).to eq("items" => [{ "id" => "SKU-1", "line" => "Tênis Runner 42" }])
    end
  end

  # The correlation the envelope reads (`state.current_tool_call`)
  # used to be ONE slot on the shared TurnState. RubyLLM 1.16 runs each tool call
  # of a batch in its own fiber — `before_tool_call` → `tool.call` →
  # `after_tool_result` all inside it — so with a single slot the second call's id
  # overwrote the first's between the callback and the read: the side-effect got
  # checkpointed under the WRONG id, and a resume then skips the wrong tool or
  # re-runs a non-idempotent one. Silent, and only reachable under concurrency.
  describe "per-call correlation under CONCURRENT tool calls (fiber-scoped)" do
    class EnvYieldingTool
      def name = "charge"
      def call(_args) = "charged"
    end

    # Models what the gem really does per call, in ONE fiber: run the
    # `before_tool_call` callbacks (which set the correlation and then do work that
    # CAN yield — our hooks plus the event emit), and only afterwards invoke the
    # tool. The yield between the write and the envelope's read is the whole race:
    # with one shared slot, the fiber that yields longest comes back and reads
    # SOMEBODY ELSE'S id. `settle` staggers the two so the interleaving is forced,
    # not hoped for.
    def concurrent_call(state, env, call_id, settle:)
      state.current_tool_call = Struct.new(:id).new(call_id)
      Async::Task.current.sleep(settle)
      env.call({ "id" => call_id })
    end

    # A writes, then sleeps LONGER than B: B writes over the slot and finishes
    # first, so A resumes to find B's id. Deterministic ordering, no flake.
    def two_interleaved_calls(state, env, results = {})
      Sync do |task|
        [["call-A", 0.05], ["call-B", 0.01]].map do |id, settle|
          task.async { results[id] = concurrent_call(state, env, id, settle: settle) }
        end.each(&:wait)
      end
      results
    end

    it "checkpoints each call under its OWN id (was: both under the last writer's)" do
      registry = FakeToolRegistry.new(side_effect_names: ["charge"])
      state = state_for
      env = envelope(EnvYieldingTool.new, state, tool_registry: registry)

      two_interleaved_calls(state, env)

      expect(checkpoint_store.side_effects("t", turn: 1)).to contain_exactly("call-A", "call-B")
    end

    it "skips ONLY the call that already ran, and runs the other (resume correctness)" do
      state = state_for
      env = envelope(EnvYieldingTool.new, state, skip_side_effects: ["call-B"])

      results = two_interleaved_calls(state, env)

      # With one shared slot, A read B's id and was skipped in B's place: the
      # non-idempotent call the resume was meant to protect ran anyway, and the
      # one it was meant to run did not.
      expect(results["call-B"]).to eq({ "skipped" => "already_executed" })
      expect(results["call-A"]).to eq("charged")
    end

    it "traces each call with its own id" do
      recorder = Class.new do
        attr_reader :entries
        def initialize = (@entries = [])
        def record(session_id:, entry:) = @entries << entry
      end.new
      state = state_for(session_id: "s1")
      env = envelope(EnvYieldingTool.new, state, trace_recorder: recorder)

      two_interleaved_calls(state, env)

      expect(recorder.entries.map { |e| e["call_id"] }).to contain_exactly("call-A", "call-B")
    end
  end
end

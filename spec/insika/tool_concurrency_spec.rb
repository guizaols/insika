# frozen_string_literal: true

require "spec_helper"
require "async"
require "insika/tools/load_skill"

# +: the switch for parallel tool calls, and the two safety
# properties that had to exist before it could be turned on at all.
#
#   · — approvals and concurrency deadlock. `Executor#request_approval` blocks
#     on `actor.await(:approval)`, and that mailbox is ONE queue per task: two
#     fibers waiting there share it, `dequeue` wakes exactly one, the message is
#     consumed, and the other fiber hangs until `approval_timeout` (~1h). So a turn
#     with any approval-required tool runs serially, and says so once.
#   · — the MODEL decides the fan-out. Without a cap, a batch of 15 data-tools
#     is 15 simultaneous requests to one upstream. The cap is a semaphore shared by
#     every ToolEnvelope of the turn.
#
# The gem-side facts these lean on (fiber-per-call, completion-order results, a
# failing sibling not stopping the batch) are pinned against the REAL gem in
# ruby_llm_contract_spec.rb; here we pin OUR decisions.
RSpec.describe "tool concurrency" do
  def profile(concurrency: nil, **limits)
    limits[:tool_concurrency] = concurrency unless concurrency.nil?
    Insika::AgentProfile.build(id: "a", model: "m", limits: limits)
  end

  def state(concurrency: nil, requires_approval: [], task_id: "t", **limits)
    st = Insika::TurnState.new(task: Struct.new(:id, :session_id).new(task_id, nil),
                               profile: profile(concurrency: concurrency, **limits),
                               turn: 1, message: "oi")
    st.requires_approval = requires_approval
    st
  end

  describe "the knob (limits[:tool_concurrency])" do
    it "is off by default — one number, and 1 means serial" do
      expect(Insika::AgentProfile::DEFAULT_LIMITS[:tool_concurrency]).to eq(1)
      expect(state.tool_concurrency).to be_nil
    end

    it "nil / 0 / 1 all mean off (parity), N > 1 is the cap" do
      expect(state(concurrency: nil).tool_concurrency).to be_nil
      expect(state(concurrency: 0).tool_concurrency).to be_nil
      expect(state(concurrency: 1).tool_concurrency).to be_nil
      expect(state(concurrency: 4).tool_concurrency).to eq(4)
    end

    it "is reachable from the DSL with no new field (`limit` already generalizes)" do
      pack = Insika.agent("shop") { limit :tool_concurrency, 3 }.to_pack
      expect(pack.config[:limits][:tool_concurrency]).to eq(3)
    end
  end

  describe "a turn with approvals runs serially" do
    it "requested stays 4, effective becomes nil when the Resolution requires approval" do
      st = state(concurrency: 4, requires_approval: ["refund"])
      expect(st.requested_tool_concurrency).to eq(4)
      expect(st.tool_concurrency).to be_nil
    end

    it "is per-TURN: the same profile with an empty requires_approval keeps the cap" do
      expect(state(concurrency: 4, requires_approval: []).tool_concurrency).to eq(4)
    end
  end

  describe "ChatBuilder — the only place the gem is told to parallelize" do
    let(:event_stream) { SpyEventStream.new }

    def builder
      Insika::ChatBuilder.new(tool_registry: Object.new,
                              skill_catalog: instance_double("Insika::SkillCatalog"),
                              checkpoint_store: Object.new, event_stream: event_stream,
                              hooks: Insika::Hooks.new)
    end

    def configure(st)
      chat = FakeChat.new
      st.context = Struct.new(:system).new("SOUL")
      st.allowed_tools = [Insika::Tools::LoadSkill.new(instance_double("Insika::SkillCatalog"), [])]
      st.allowed_skills = []
      builder.configure_chat(chat, st)
      chat
    end

    it "passes concurrency: :fibers when the turn has a cap" do
      expect(configure(state(concurrency: 4)).concurrency).to eq(:fibers)
    end

    it "passes no concurrency at all when off — the serial call shape is untouched" do
      expect(configure(state).concurrency).to be_nil
    end

    it ":fibers is the only mode ever sent (:threads breaks the envelope and the store)" do
      expect(configure(state(concurrency: 8)).concurrency).to eq(:fibers)
    end

    it "warns ONCE when the profile asked for it and the turn cannot have it" do
      configure(state(concurrency: 4, requires_approval: %w[refund wire]))

      warning = event_stream.events.find { |e| e.type == :provider_warning }
      expect(warning.data[:provider]).to eq("tool_concurrency")
      expect(warning.data[:message]).to include("4", "2 tool(s) require approval", "refund, wire")
      expect(event_stream.events.count { |e| e.type == :provider_warning }).to eq(1)
    end

    it "stays quiet when concurrency was never requested (no noise on the serial default)" do
      configure(state(requires_approval: ["refund"]))
      expect(event_stream.events).to be_empty
    end
  end

  describe "the cap on in-flight calls" do
    let(:assembly) do
      Insika::ToolAssembly.new(tool_registry: Object.new, capability_registry: nil,
                               event_stream: SpyEventStream.new, checkpoint_store: Object.new,
                               tool_trace_store: nil)
    end

    it "installs one shared gate per turn, sized by the knob" do
      st = state(concurrency: 3)
      assembly.wrap_tools([], st)
      expect(st.tool_gate).to be_a(Async::Semaphore)
      expect(st.tool_gate.limit).to eq(3)
    end

    it "installs NO gate when concurrency is off (serial path allocates nothing)" do
      st = state
      assembly.wrap_tools([], st)
      expect(st.tool_gate).to be_nil
    end

    it "installs no gate for a turn downgraded" do
      st = state(concurrency: 3, requires_approval: ["refund"])
      assembly.wrap_tools([], st)
      expect(st.tool_gate).to be_nil
    end

    # The property that matters: however many calls the MODEL fans out, at most
    # `tool_concurrency` are inside the real tool at any instant.
    it "never lets more than N run at once, whatever the fan-out" do
      in_flight = 0
      peak = 0
      tool = Class.new do
        def initialize(&body) = (@body = body)
        def name = "io"
        def call(_args) = @body.call
      end.new do
        in_flight += 1
        peak = [peak, in_flight].max
        Async::Task.current.sleep(0.01)
        in_flight -= 1
        "ok"
      end

      st = state(concurrency: 2)
      envelopes = assembly.wrap_tools(Array.new(9) { tool }, st)

      Sync { envelopes.map { |e| Async { e.call({}) } }.each(&:wait) }

      expect(peak).to eq(2)
    end

    it "runs unbounded (all at once) when the gate is absent — proves the cap is what bounds it" do
      in_flight = 0
      peak = 0
      tool = Class.new do
        def initialize(&body) = (@body = body)
        def name = "io"
        def call(_args) = @body.call
      end.new do
        in_flight += 1
        peak = [peak, in_flight].max
        Async::Task.current.sleep(0.01)
        in_flight -= 1
        "ok"
      end

      st = state # off
      envelopes = assembly.wrap_tools(Array.new(9) { tool }, st)

      Sync { envelopes.map { |e| Async { e.call({}) } }.each(&:wait) }

      expect(peak).to eq(9)
    end

    it "the per-call tool_timeout clock starts AFTER a slot is granted, not while queueing" do
      # Cap 1, three calls of 0.15s, tool_timeout 0.25s. The third waits ~0.3s for a
      # slot: it times out if the deadline covers the wait, and succeeds if the
      # envelope acquires first and starts the clock after.
      tool = Class.new do
        def name = "io"

        def call(_args)
          Async::Task.current.sleep(0.15)
          "ok"
        end
      end.new

      st = state(concurrency: 4, tool_timeout: 0.25)
      envelopes = assembly.wrap_tools([tool, tool, tool], st)
      st.tool_gate = Async::Semaphore.new(1) # squeeze the cap to force queueing

      results = Sync { envelopes.map { |e| Async { e.call({}) } }.map(&:wait) }

      expect(results).to eq(%w[ok ok ok])
    end
  end
end

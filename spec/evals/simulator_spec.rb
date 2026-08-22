# frozen_string_literal: true

require "spec_helper"

# The Simulator: a simulated customer talks to the target agent
# until `max_turns` or a stop marker. Pure over the injected seams — a fake
# transport for the target and a scripted ask for the persona — so the loop and
# the safety gate are testable offline.
RSpec.describe Insika::Evals::Simulator do
  # A transport double: answers scripted text per message, records what it saw.
  class FakeAgentTransport
    attr_reader :seen

    def initialize(&script)
      @script = script
      @seen = []
    end

    def turn(agent:, conv:, message:)
      @seen << { agent: agent, conv: conv, message: message }
      text, error = @script.call(message)
      Insika::Evals::TurnOutcome.new(
        result: Insika::Evals::TurnResult.new(output_text: text.to_s, tool_calls: [], error: error),
        ttfb: 1.0, total: 2.0, usage: nil
      )
    end
  end

  # A scripted persona ask: each call returns the next entry (or a stop marker).
  # `repeat:` cycles a single reply forever (a persona that keeps talking).
  class ScriptedAsk
    def initialize(replies, repeat: nil)
      @replies = Array(replies)
      @repeat = repeat
    end

    def call(_prompt) = @replies.empty? ? @repeat.to_s : @replies.shift.to_s
  end

  def persona(overrides = {})
    Insika::Evals::PersonaLoader.build({
      "goal" => "find a gift under R$100", "style" => "short",
      "opens_with" => "oi, queria um presente",
      "knows" => { "budget" => "100" }, "max_turns" => 5
    }.merge(overrides.transform_keys(&:to_s)))
  end

  def safe
    described_class::Safety.new(side_effect_tools: [])
  end

  describe "the loop" do
    it "runs the persona's opens_with into the agent, then asks the persona to continue" do
      agent = FakeAgentTransport.new { |m| m == "oi, queria um presente" ? ["que tal um relógio?"] : ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["tá, obrigada <<goal_met>>"]), safety: safe)
      run = sim.run(persona: persona, agent: "loja", conv: "sim-1")

      expect(agent.seen.first[:message]).to eq("oi, queria um presente")
      expect(agent.seen.map { |s| s[:conv] }).to eq(["sim-1"])
      expect(run.simulated).to be(true)
      expect(run.simulated?).to be(true)
      expect(run.stop).to eq(:goal_met)
      expect(run.turns).to eq(1)
    end

    it "records the full transcript, stripping the stop marker" do
      agent = FakeAgentTransport.new { ["bom dia!"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["oi <<goal_met>>"]), safety: safe)
      run = sim.run(persona: persona, agent: "loja", conv: "sim-1")

      roles = run.transcript.map { |m| m[:role] }
      expect(roles).to eq(%w[user assistant user])
      expect(run.transcript.last[:text]).to eq("oi") # marker stripped
      expect(run.transcript[1][:text]).to eq("bom dia!")
    end

    it "records a gave_up stop" do
      agent = FakeAgentTransport.new { ["não sei"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["ah, deixa pra lá <<gave_up>>"]), safety: safe)
      run = sim.run(persona: persona, agent: "loja", conv: "sim-1")
      expect(run.stop).to eq(:gave_up)
      expect(run.error).to be_nil
    end

    it "stops at max_turns when the persona never emits a marker" do
      agent = FakeAgentTransport.new { ["mais alguma coisa?"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new([], repeat: "não, obrigado"), safety: safe)
      run = sim.run(persona: persona(max_turns: 3), agent: "loja", conv: "sim-1")
      expect(run.stop).to eq(:max_turns)
      expect(run.turns).to eq(3)
      expect(run.transcript.size).to eq(6) # 3 user + 3 assistant
    end

    it "aborts on an errored agent turn and records the error" do
      agent = FakeAgentTransport.new { ["", "boom"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new([]), safety: safe)
      run = sim.run(persona: persona, agent: "loja", conv: "sim-1")
      expect(run.stop).to eq(:error)
      expect(run.error).to eq("boom")
      expect(run.turns).to eq(1)
    end

    it "records an error when the persona model produces an empty message" do
      agent = FakeAgentTransport.new { ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new([""]), safety: safe)
      run = sim.run(persona: persona, agent: "loja", conv: "sim-1")
      expect(run.stop).to eq(:error)
      expect(run.error).to include("empty message")
    end
  end

  describe "the safety gate" do
    def unsafe(transport)
      described_class.new(transport: transport, ask: ScriptedAsk.new(["oi"]),
                          safety: described_class::Safety.new(side_effect_tools: %w[create_order]))
    end

    it "refuses a target with side-effect tools unless staging or eval profile" do
      agent = FakeAgentTransport.new { ["ok"] }
      expect { unsafe(agent).run(persona: persona, agent: "loja", conv: "sim-1") }
        .to raise_error(described_class::UnsafeTarget, /create_order/)
    end

    it "runs when declared staging" do
      agent = FakeAgentTransport.new { ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["ok <<goal_met>>"]),
                                safety: described_class::Safety.staging)
      expect { sim.run(persona: persona, agent: "loja", conv: "sim-1") }.not_to raise_error
    end

    it "runs when the run uses an eval profile" do
      agent = FakeAgentTransport.new { ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["ok <<goal_met>>"]),
                                safety: described_class::Safety.new(eval_profile: true))
      expect { sim.run(persona: persona, agent: "loja", conv: "sim-1") }.not_to raise_error
    end

    # A bare `eval_profile: true` on a target with a KNOWN side-effect
    # tool is a trust-me flag — the profile must declare it swaps that tool.
    it "refuses a bare eval profile that does not swap the derived side-effect tools" do
      agent = FakeAgentTransport.new { ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["ok"]),
                                safety: described_class::Safety.new(eval_profile: true,
                                                                    side_effect_tools: %w[create_order]))
      expect { sim.run(persona: persona, agent: "loja", conv: "sim-1") }
        .to raise_error(described_class::UnsafeTarget, /must swap EVERY side-effect tool/)
    end

    it "runs an eval profile whose swap covers every derived side-effect tool" do
      agent = FakeAgentTransport.new { ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["ok <<goal_met>>"]),
                                safety: described_class::Safety.new(eval_profile: true,
                                                                    side_effect_tools: %w[create_order],
                                                                    swapped_tools: %w[create_order]))
      expect { sim.run(persona: persona, agent: "loja", conv: "sim-1") }.not_to raise_error
    end

    it "runs when the derived side-effect list is empty" do
      agent = FakeAgentTransport.new { ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["ok <<goal_met>>"]),
                                safety: described_class::Safety.new(side_effect_tools: []))
      expect { sim.run(persona: persona, agent: "loja", conv: "sim-1") }.not_to raise_error
    end
  end

  describe "to_h" do
    it "always reports simulated: true" do
      agent = FakeAgentTransport.new { ["ok"] }
      sim = described_class.new(transport: agent, ask: ScriptedAsk.new(["oi <<goal_met>>"]), safety: safe)
      h = sim.run(persona: persona, agent: "loja", conv: "sim-1").to_h
      expect(h["simulated"]).to be(true)
      expect(h["stop"]).to eq("goal_met")
    end
  end
end

# The DERIVED eval profile: the engine marks side_effect on tools, so the swap
# list is a fact of the registry, never a hand-maintained list.
RSpec.describe Insika::Evals::EvalProfile do
  class FakeRegistry
    def initialize(names, side_effect: [])
      @names = names
      @side = Array(side_effect)
    end

    def names = @names
    def side_effect?(name) = @side.include?(name.to_s)
  end

  def profile(tools_allow: nil, tools_deny: nil)
    Insika::AgentProfile.build(id: "loja", model: "m", tools_allow: tools_allow, tools_deny: tools_deny)
  end

  it "derives side-effect tools from the agent's reachable set" do
    reg = FakeRegistry.new(%w[search_products create_order delete_order], side_effect: %w[create_order])
    expect(described_class.side_effect_tools(profile(tools_allow: %w[search_products create_order]), reg))
      .to eq(%w[create_order])
  end

  it "respects tools_deny (deny wins)" do
    reg = FakeRegistry.new(%w[create_order], side_effect: %w[create_order])
    expect(described_class.side_effect_tools(profile(tools_allow: %w[create_order], tools_deny: %w[create_order]), reg))
      .to eq([])
  end

  it "treats an open allowlist (nil) as every registered tool" do
    reg = FakeRegistry.new(%w[a create_order], side_effect: %w[create_order])
    expect(described_class.side_effect_tools(profile, reg)).to eq(%w[create_order])
  end

  it "says an agent with no reachable side-effect tool is safe" do
    reg = FakeRegistry.new(%w[search_products], side_effect: %w[create_order])
    expect(described_class.safe?(profile(tools_allow: %w[search_products]), reg)).to be(true)
  end

  describe "the dry-run overlay" do
    it "resolves the swapped names to a dry-run fake and delegates the rest" do
      base = FakeRegistry.new(%w[search create], side_effect: %w[create])
      overlay = described_class.registry(base, side_effect_tools: %w[create])
      tool = overlay.resolve("create")
      expect(tool).to be_a(Insika::Evals::Simulator::DryRunTool)
      expect(tool.call({})["dry_run"]).to be(true)

      # The overlay answers the same surface: side_effect? says a swapped tool is
      # no longer a side effect (the fake cannot write).
      expect(overlay.side_effect?("create")).to be(false)
      expect(overlay.side_effect?("search")).to be(false)
      expect(overlay.names).to eq(%w[search create])
    end
  end

  describe Insika::Evals::Simulator::DryRunTool do
    it "answers the tool surface and returns a dry-run envelope" do
      t = described_class.new("create_order")
      expect(t.name).to eq("create_order")
      expect(t.description).to include("DRY-RUN")
      result = t.call({ "order_id" => "1" })
      expect(result["dry_run"]).to be(true)
      expect(result["simulated"]).to be(true)
    end
  end
end
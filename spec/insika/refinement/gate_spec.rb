# frozen_string_literal: true

require "spec_helper"

# RFC-0013 §3.5 — the gate is the entire safety story of refinement. Everything
# upstream is allowed to be wrong; what must hold here is that a candidate is
# measured by RUNNING it, that the live agent is never touched, that the clone
# always goes away, and that a missing accepted state is a refusal rather than a
# green light.
RSpec.describe Insika::Refinement::Gate do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:agent_files) { Insika::AgentFileStore.new(config_store: config_store) }
  let(:goldens) { Insika::GoldenStore.new(config_store: config_store) }
  let(:baselines) { Insika::BaselineStore.new(config_store: config_store) }

  TOOLS = "# Tools\n\nUse shipping_quote to quote freight.\n#{"Be brief and warm.\n" * 20}"

  # Records which agent each turn addressed, and answers per a script keyed by case
  # id. That is all the gate needs from a transport, and using a real one here would
  # measure DeepSeek rather than the gate.
  class GateTransportDouble
    attr_reader :agents_seen

    def initialize(script, usage: nil) = (@script = script; @usage = usage; @agents_seen = [])

    def turn(agent:, conv:, message:)
      @agents_seen << agent
      outcome = @script[conv.split("eval-").last] || { text: "ok", tools: [] }
      Insika::Evals::TurnOutcome.new(
        result: Insika::Evals::TurnResult.new(output_text: outcome[:text],
                                              tool_calls: Array(outcome[:tools]).map { |t| { "name" => t, "status" => "ok" } },
                                              error: outcome[:error]),
        ttfb: 1.0, total: 2.0, usage: @usage
      )
    end
  end

  def seed_agent(id: "support", refinement: { "mode" => "propose", "files" => ["TOOLS.md"] })
    profiles.put(Insika::AgentProfile.build(id: id, model: "m", provider: :deepseek,
                                            refinement: refinement, prompt_files: ["TOOLS.md"]))
    agent_files.write(id, "TOOLS.md", TOOLS)
  end

  def seed_case(id: "quotes-freight", agent: "support", must_not: [])
    goldens.write({ "id" => id, "agent" => agent,
                    "turns" => [{ "user" => "quanto custa o frete?" }],
                    "expect" => { "tools_called" => ["shipping_quote"], "must_not" => must_not } })
  end

  def candidate(before: "Use shipping_quote to quote freight.",
                after: "Use shipping_quote to quote freight. Ask for the CEP first.")
    Insika::Refinement::CandidateBuilder.build(
      { "proposer" => "test", "edits" => [{ "file" => "TOOLS.md", "op" => "replace",
                                            "before" => before, "after" => after }] },
      allowlist: ["TOOLS.md"], contents: { "TOOLS.md" => TOOLS }
    )
  end

  def gate(script: { "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] } }, usage: nil)
    transport = GateTransportDouble.new(script, usage: usage)
    [described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                         baselines: baselines, transport_factory: -> { transport }),
     transport]
  end

  def baseline!(cases) = baselines.put("support", { "cases" => cases })

  before { seed_agent }

  describe "the refusals that happen before anything is cloned" do
    # D4: declaring the cases is the price of admission to automated editing.
    it "refuses an agent with no golden cases" do
      baseline!({})
      report, = gate.first.then { |g| [g.score(agent_id: "support", candidate: candidate, run_id: "r1")] }
      expect(report.passed).to be(false)
      expect(report.reason).to match(/no golden cases/)
    end

    # The trap this store exists to close: `Baseline.compare` only compares cases
    # present in BOTH sides, so an absent baseline reports zero regressions — a green
    # light that means "we did not look".
    it "refuses when no baseline was ever recorded, instead of passing vacuously" do
      seed_case
      report = gate.first.score(agent_id: "support", candidate: candidate, run_id: "r1")
      expect(report.passed).to be(false)
      expect(report.reason).to match(/no recorded baseline/)
    end

    # The same hole as a missing baseline, with a record standing in front of it.
    # `compare` only reports a regression against a case the baseline had PASSING, so
    # a baseline where nothing passes cannot produce one — every candidate sails
    # through, including a harmful one. Found by running the gate against a real
    # agent after a broken replay recorded an all-red baseline.
    it "refuses an all-red baseline, which would let every candidate through" do
      seed_case
      baseline!("quotes-freight" => { "pass" => false, "score" => nil })
      report = gate.first.score(agent_id: "support", candidate: candidate, run_id: "r1")

      expect(report.passed).to be(false)
      expect(report.reason).to match(/no PASSING case.*every candidate would pass/m)
    end

    it "refuses a baseline recorded with no cases at all" do
      seed_case
      baseline!({})
      expect(gate.first.score(agent_id: "support", candidate: candidate, run_id: "r1").reason)
        .to match(/no PASSING case/)
    end

    # One green case is enough to make the gate meaningful — the refusal is about
    # "nothing can regress", not about coverage.
    it "runs when at least one baselined case passes, even alongside failing ones" do
      seed_case
      seed_case(id: "another")
      baseline!("quotes-freight" => { "pass" => true, "score" => nil },
                "another" => { "pass" => false, "score" => nil })
      report = gate.first.score(agent_id: "support", candidate: candidate, run_id: "r1")
      expect(report.reason).to be_nil
    end

    it "clones nothing when it refuses" do
      seed_case
      g, transport = gate
      g.score(agent_id: "support", candidate: candidate, run_id: "r1")
      expect(transport.agents_seen).to be_empty
      expect(profiles.ids).to eq(["support"])
    end

    # The third shape of "a gate that cannot fail", and the one this shipped with.
    # `CaseResult#pass?` reads a MISSING judge verdict as a pass, so a replay with no
    # judge scores every rubric case as passing — against a baseline recorded WITH a
    # judge that is not a weaker measurement, it is an inverted one.
    #
    # Measured, not reasoned: gating the real pilot with `settings["evals"]` unset
    # reported 6/6 with no regression against a baseline the same corpus had just
    # scored 2/6.
    describe "a judged baseline with no judge" do
      before { seed_case }

      def judged_gate(judge_factory)
        transport = GateTransportDouble.new({ "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] } })
        described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                            baselines: baselines, transport_factory: -> { transport },
                            judge_factory: judge_factory)
      end

      it "refuses, naming where to configure the judge" do
        baseline!("quotes-freight" => { "pass" => true, "score" => 0.9 })
        report = judged_gate(-> { nil }).score(agent_id: "support", candidate: candidate, run_id: "r1")

        expect(report.passed).to be(false)
        expect(report.reason).to match(/carries judge scores but no judge is configured/)
        expect(report.reason).to match(/Settings → Evals/)
        expect(profiles.ids).to eq(["support"]) # nothing was cloned, nothing was spent
      end

      it "runs when the judge is there" do
        baseline!("quotes-freight" => { "pass" => true, "score" => 0.9 })
        judge = Struct.new(:calls) do
          def score(golden:, result:) = Insika::Evals::Judge::Verdict.new(score: 0.9, pass: true, reason: "ok")
        end.new(0)
        report = judged_gate(-> { judge }).score(agent_id: "support", candidate: candidate, run_id: "r1")

        expect(report.reason).to be_nil
        expect(report.passed).to be(true)
      end

      # A baseline with no scores was recorded blind too, so both sides are equally
      # deterministic: weak, but not inverted. Refusing it would wedge every
      # deployment that never configured a judge, which is the common case.
      it "runs against an unjudged baseline with no judge" do
        baseline!("quotes-freight" => { "pass" => true, "score" => nil })
        report = judged_gate(nil).score(agent_id: "support", candidate: candidate, run_id: "r1")

        expect(report.reason).to be_nil
      end
    end
  end

  describe "the clone" do
    before { seed_case and baseline!("quotes-freight" => { "pass" => true, "score" => nil }) }

    it "replays against the CLONE, never the live agent" do
      g, transport = gate
      g.score(agent_id: "support", candidate: candidate, run_id: "abc-def-99")
      expect(transport.agents_seen.uniq).to eq(["support-cand-abcdef99"])
    end

    it "leaves the live agent's files untouched" do
      gate.first.score(agent_id: "support", candidate: candidate, run_id: "r1")
      expect(agent_files.read("support", "TOOLS.md")).to eq(TOOLS)
      expect(agent_files.versions("support", "TOOLS.md")).to be_empty
    end

    it "gives the clone the edited file and everything else the agent had" do
      agent_files.write("support", "IDENTITY.md", "You are Bia.\n")
      seen = nil
      g, = gate
      allow(agent_files).to receive(:write).and_wrap_original do |orig, agent, file, body, **kw|
        seen = { file => body } .merge(seen || {}) if agent.start_with?("support-cand-")
        orig.call(agent, file, body, **kw)
      end
      g.score(agent_id: "support", candidate: candidate, run_id: "r1")

      expect(seen.keys).to contain_exactly("TOOLS.md", "IDENTITY.md")
      expect(seen["TOOLS.md"]).to include("Ask for the CEP first.")
      expect(seen["IDENTITY.md"]).to eq("You are Bia.\n")
    end

    # A leftover `-cand-` agent is servable at /v1/responses by anyone who knows the
    # id. Leaking one is an exposure, not clutter.
    it "deletes the clone afterwards, profile and files" do
      gate.first.score(agent_id: "support", candidate: candidate, run_id: "r1")
      expect(profiles.ids).to eq(["support"])
      expect(agent_files.list("support-cand-r1")).to be_empty
    end

    it "deletes the clone even when the replay blows up" do
      exploding = Class.new { def turn(**) = raise("provider down") }.new
      g = described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                              baselines: baselines, transport_factory: -> { exploding })
      report = g.score(agent_id: "support", candidate: candidate, run_id: "r1")

      expect(report.passed).to be(false)
      expect(report.reason).to match(/gate failed to run.*provider down/)
      expect(profiles.ids).to eq(["support"])
    end
  end

  describe "the verdict" do
    before { seed_case }

    it "passes a candidate that keeps every baseline case passing" do
      baseline!("quotes-freight" => { "pass" => true, "score" => nil })
      report = gate.first.score(agent_id: "support", candidate: candidate, run_id: "r1")

      expect(report.passed).to be(true)
      expect(report.cases).to eq(1)
      expect(report.passed_cases).to eq(1)
      expect(report.regressions).to be_empty
      expect(report.report["total"]).to eq(1)
    end

    it "fails a candidate that regresses a case the baseline had passing" do
      baseline!("quotes-freight" => { "pass" => true, "score" => nil })
      g, = gate(script: { "quotes-freight" => { text: "sei lá", tools: [] } })
      report = g.score(agent_id: "support", candidate: candidate, run_id: "r1")

      expect(report.passed).to be(false)
      expect(report.reason).to match(/1 regression\(s\).*quotes-freight \(pass→fail\)/)
      expect(report.regressions.first["kind"]).to eq("pass→fail")
    end

    # A case the baseline already had failing must not wedge the gate: refinement
    # exists to fix those, and blocking on them means nothing can ever land. It needs
    # a green case beside it, or the all-red refusal above (correctly) fires first.
    it "does not block on a case that was already failing" do
      seed_case(id: "greets")
      baseline!("quotes-freight" => { "pass" => false, "score" => nil },
                "greets" => { "pass" => true, "score" => nil })
      g, = gate(script: { "quotes-freight" => { text: "sei lá", tools: [] },
                          "greets" => { text: "oi!", tools: ["shipping_quote"] } })
      report = g.score(agent_id: "support", candidate: candidate, run_id: "r1")
      expect(report.passed).to be(true)
      expect(report.regressions).to be_empty
    end
  end

  # RFC-0014 §3.2 again, from inside the gate. Without this the gate and
  # `evals/run.rb` — the two callers of the ONE evaluator §3.7 insists on — disagree
  # about what the corpus measures: the CLI skips a case the agent cannot satisfy,
  # the gate runs it and counts a failure.
  describe "capability resolution" do
    let(:caps) do
      Class.new do
        def initialize(tools) = @tools = tools
        def for(_agent) = { "tools" => @tools, "capabilities" => [] }
      end
    end

    before do
      goldens.write({ "id" => "needs-voucher", "agent" => "support",
                      "turns" => [{ "user" => "tem cupom?" }],
                      "requires" => { "tools" => ["search_voucher"] },
                      "expect" => { "tools_called" => ["search_voucher"] } })
      seed_case
      baseline!("quotes-freight" => { "pass" => true, "score" => nil })
    end

    def gate_with(capabilities_factory)
      transport = GateTransportDouble.new({ "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] } })
      described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                          baselines: baselines, transport_factory: -> { transport },
                          capabilities_factory: capabilities_factory)
    end

    it "skips a case the agent cannot satisfy, instead of scoring it as a failure" do
      g = gate_with(-> { caps.new(%w[shipping_quote]) })
      report = g.score(agent_id: "support", candidate: candidate, run_id: "r1")

      skipped = report.report["cases"].find { |c| c["id"] == "needs-voucher" }
      expect(skipped["skipped"]).to match(/search_voucher/)
      expect(report.report["skipped"]).to eq(1)
      expect(report.passed).to be(true)
    end

    it "runs the case when capabilities cannot be resolved — silence must not shrink a suite" do
      g = gate_with(-> { nil })
      report = g.score(agent_id: "support", candidate: candidate, run_id: "r1")
      expect(report.report["skipped"]).to eq(0)
    end
  end

  it "names the clone after the run so two gates cannot collide" do
    g, = gate
    expect(g.clone_id_for("support", "9f2c1b40-aaaa")).to eq("support-cand-9f2c1b40")
    expect(g.clone_id_for("support", "1111-2222")).to eq("support-cand-11112222")
  end

  # RFC-0013 §3.9: a gate is the expensive half of refinement and a loop whose cost
  # is invisible is one nobody can decide to keep. The panel's budget spends this.
  describe "what the replay cost" do
    before do
      seed_case
      seed_case(id: "asks-cep")
      baseline!("quotes-freight" => { "pass" => true }, "asks-cep" => { "pass" => true })
    end

    it "sums what the deployment reported across the replayed cases" do
      g, = gate(script: { "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] },
                          "asks-cep" => { text: "R$ 20", tools: ["shipping_quote"] } },
                usage: { "total_tokens" => 300 })
      expect(g.score(agent_id: "support", candidate: candidate, run_id: "r1").tokens).to eq(600)
    end

    # The engine's `total_tokens` is input + output and EXCLUDES the cached prefix.
    # Measured on the pilot: a real turn reports 88 total against 26_624 cached, so a
    # ceiling built on `total_tokens` alone would let a run send ~300× what it said.
    it "counts what the turn SENT, prompt cache included" do
      g, = gate(script: { "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] },
                          "asks-cep" => { text: "R$ 20", tools: ["shipping_quote"] } },
                usage: { "total_tokens" => 88, "cached_tokens" => 26_624 })
      report = g.score(agent_id: "support", candidate: candidate, run_id: "r1")

      expect(report.tokens).to eq((88 + 26_624) * 2)
      expect(report.cached).to eq(26_624 * 2)
    end

    it "is nil when the provider metered nothing, and nil on a refusal" do
      g, = gate(script: { "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] },
                          "asks-cep" => { text: "R$ 20", tools: ["shipping_quote"] } })
      expect(g.score(agent_id: "support", candidate: candidate, run_id: "r1").tokens).to be_nil

      baselines.put("nobody", { "cases" => {} })
      refused = g.score(agent_id: "support", candidate: candidate, run_id: "r1", tolerance: 0)
      expect(refused.tokens).to be_nil
    end
  end
end

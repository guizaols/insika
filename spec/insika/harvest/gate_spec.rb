# frozen_string_literal: true

require "spec_helper"

# RFC-0035 C7 — the eval half of the double gate. The Refinement::Gate
# mechanism with the skill's apply (D7): clone the agent, write the candidate
# skill into the clone's agent-scoped SkillStore, enable it on the clone's
# allowlist, reload the catalog, replay the golden set, compare to the
# accepted baseline, destroy the clone. The skill is gated by being USABLE,
# not by prose — the whole safety story: everything upstream can be wrong and
# the worst outcome is a candidate that fails to improve a score and never
# lands. Judges are MANDATORY in the three P18 shapes.
RSpec.describe Insika::Harvest::Gate do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:agent_files) { Insika::AgentFileStore.new(config_store: config_store) }
  let(:goldens) { Insika::GoldenStore.new(config_store: config_store) }
  let(:baselines) { Insika::BaselineStore.new(config_store: config_store) }
  let(:skill_store) { Insika::SkillStore.new(config_store: config_store) }
  let(:skill_catalog) { Insika::SkillCatalog.new([], store: skill_store) }

  TOOLS = "# Tools\n\nUse shipping_quote to quote freight.\n#{"Be brief and warm.\n" * 20}"

  # Scripted transport: records which agent each turn addressed and answers
  # per case id — all the gate needs (a real transport would measure the
  # provider, not the gate).
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

  def seed_agent(id: "support", skills: nil)
    profiles.put(Insika::AgentProfile.build(id: id, model: "m", provider: :deepseek,
                                            prompt_files: ["TOOLS.md"], skills: skills))
    agent_files.write(id, "TOOLS.md", TOOLS)
  end

  def seed_case(id: "quotes-freight", agent: "support", must_not: [])
    goldens.write({ "id" => id, "agent" => agent,
                    "turns" => [{ "user" => "quanto custa o frete?" }],
                    "expect" => { "tools_called" => ["shipping_quote"], "must_not" => must_not } })
  end

  # A candidate skill: the engine's own stamped shape — a full SKILL.md body.
  def candidate(name: "pix-recovery", body: "## Steps\n1. Ask for the CEP first.\n")
    { "name" => name,
      "description" => "recover pending payments",
      "body" => "---\nname: #{name}\ndescription: recover pending payments\n---\n#{body}",
      "triggers" => %w[pix pagamento] }
  end

  def gate(script: { "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] } }, usage: nil)
    transport = GateTransportDouble.new(script, usage: usage)
    [described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                         baselines: baselines, skill_store: skill_store,
                         skill_catalog: skill_catalog, transport_factory: -> { transport }),
     transport]
  end

  def baseline!(cases) = baselines.put("support", { "cases" => cases })

  before { seed_agent }

  describe "the P18 refusals — judges mandatory in the three shapes" do
    it "refuses an agent with no golden cases" do
      baseline!({})
      report = gate.first.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(report.passed).to be(false)
      expect(report.reason).to match(/no golden cases/)
    end

    it "refuses when no baseline was ever recorded, instead of passing vacuously" do
      seed_case
      report = gate.first.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(report.passed).to be(false)
      expect(report.reason).to match(/no recorded baseline/)
    end

    it "refuses an all-red baseline, which would let every candidate through" do
      seed_case
      baseline!("quotes-freight" => { "pass" => false, "score" => nil })
      report = gate.first.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(report.passed).to be(false)
      expect(report.reason).to match(/no PASSING case/)
    end

    it "refuses a judged baseline with no judge — a rubric'd case with no verdict counts as a pass" do
      seed_case
      baseline!("quotes-freight" => { "pass" => true, "score" => 0.9 })
      g = described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                              baselines: baselines, skill_store: skill_store,
                              skill_catalog: skill_catalog,
                              transport_factory: -> { GateTransportDouble.new({}) },
                              judge_factory: -> { nil })
      report = g.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(report.passed).to be(false)
      expect(report.reason).to match(/carries judge scores but no judge is configured/)
      expect(profiles.ids).to eq(["support"]) # nothing was cloned, nothing was spent
    end

    it "runs when the judge is there; runs blind against an unjudged baseline" do
      seed_case
      judge = Struct.new(:calls) do
        def score(golden:, result:) = Insika::Evals::Judge::Verdict.new(score: 0.9, pass: true, reason: "ok")
      end.new(0)
      baseline!("quotes-freight" => { "pass" => true, "score" => 0.9 })
      g = described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                              baselines: baselines, skill_store: skill_store,
                              skill_catalog: skill_catalog,
                              transport_factory: -> { GateTransportDouble.new({ "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] } }) },
                              judge_factory: -> { judge })
      expect(g.score(agent_id: "support", skill: candidate, run_id: "r1").reason).to be_nil

      baseline!("quotes-freight" => { "pass" => true, "score" => nil })
      blind = described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                                  baselines: baselines, skill_store: skill_store,
                                  skill_catalog: skill_catalog,
                                  transport_factory: -> { GateTransportDouble.new({ "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] } }) })
      expect(blind.score(agent_id: "support", skill: candidate, run_id: "r1").passed).to be(true)
    end
  end

  describe "the skill apply (D7 — gated by being usable)" do
    before { seed_case and baseline!("quotes-freight" => { "pass" => true, "score" => nil }) }

    it "writes the skill into the clone's AGENT scope, enables it on the clone's allowlist and reloads the catalog" do
      seed_agent(skills: %w[greeting])
      reloaded = false
      written_to = nil
      clone_skills = nil
      allow(skill_catalog).to receive(:reload) { reloaded = true; skill_catalog }
      allow(skill_store).to receive(:write).and_wrap_original do |orig, name, body, agent:, **kw|
        written_to = agent
        orig.call(name, body, agent: agent, **kw)
      end
      allow(profiles).to receive(:put).and_wrap_original do |orig, profile|
        clone_skills = profile.skills if profile.id.start_with?("support-harvest-")
        orig.call(profile)
      end

      gate.first.score(agent_id: "support", skill: candidate, run_id: "abc-def-99")

      expect(written_to).to eq("support-harvest-abcdef99")
      expect(clone_skills).to include("pix-recovery")
      expect(reloaded).to be(true)
      # the apply is visible DURING the gate — and gone AFTER it (destroyed
      # with the clone): the served-skill proof is in the spy + the replay
      # targeting the clone below.
    end

    it "replays against the CLONE — the clone's catalog serves the skill (the model can load_skill it)" do
      g, transport = gate
      g.score(agent_id: "support", skill: candidate, run_id: "abc-def-99")
      expect(transport.agents_seen.uniq).to eq(["support-harvest-abcdef99"])
      served = skill_catalog.find("pix-recovery", agent: "support-harvest-abcdef99")
      expect(served).to_not be_nil
      expect(served.body).to include("## Steps")
    end

    it "leaves the live agent's files, profile and skills untouched" do
      gate.first.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(agent_files.read("support", "TOOLS.md")).to eq(TOOLS)
      expect(profiles.fetch("support").skills).to be_nil
      expect(skill_store.get("pix-recovery", agent: "support")).to be_nil
    end

    it "deletes the clone afterwards — profile, files and the clone's skill record" do
      gate.first.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(profiles.ids).to eq(["support"])
      expect(agent_files.list("support-harvest-r1")).to be_empty
      expect(skill_store.get("pix-recovery", agent: "support-harvest-r1")).to be_nil
    end

    it "deletes the clone even when the replay blows up" do
      exploding = Class.new { def turn(**) = raise("provider down") }.new
      g = described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                              baselines: baselines, skill_store: skill_store,
                              skill_catalog: skill_catalog, transport_factory: -> { exploding })
      report = g.score(agent_id: "support", skill: candidate, run_id: "r1")

      expect(report.passed).to be(false)
      expect(report.reason).to match(/gate failed to run.*provider down/)
      expect(profiles.ids).to eq(["support"])
      expect(skill_store.get("pix-recovery", agent: "support-harvest-r1")).to be_nil
    end
  end

  describe "the verdict (E3's eval half)" do
    before { seed_case }

    it "passes a good candidate — no regressions, clone destroyed" do
      baseline!("quotes-freight" => { "pass" => true, "score" => nil })
      report = gate.first.score(agent_id: "support", skill: candidate, run_id: "r1")

      expect(report.passed).to be(true)
      expect(report.cases).to eq(1)
      expect(report.passed_cases).to eq(1)
      expect(report.regressions).to be_empty
      expect(profiles.ids).to eq(["support"])
    end

    it "REJECTS a known-worse candidate — the replay shows a regression the baseline had passing (the gate cannot stamp)" do
      baseline!("quotes-freight" => { "pass" => true, "score" => nil })
      seed_case(id: "never-quotes")
      baseline!("quotes-freight" => { "pass" => true, "score" => nil },
                "never-quotes" => { "pass" => true, "score" => nil })
      g, = gate(script: {
                  "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] },
                  "never-quotes" => { text: "vou responder sozinho", tools: [] }
                })
      report = g.score(agent_id: "support", skill: candidate, run_id: "r1")

      expect(report.passed).to be(false)
      expect(report.reason).to match(/regression/)
      expect(report.regressions).to_not be_empty
    end

    it "does not block on a case that was already failing" do
      seed_case(id: "greets")
      baseline!("quotes-freight" => { "pass" => false, "score" => nil },
                "greets" => { "pass" => true, "score" => nil })
      g, = gate(script: { "quotes-freight" => { text: "sei lá", tools: [] },
                          "greets" => { text: "oi!", tools: ["shipping_quote"] } })
      report = g.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(report.passed).to be(true)
      expect(report.regressions).to be_empty
    end
  end

  it "names the clone after the run so two gates cannot collide" do
    g, = gate
    expect(g.clone_id_for("support", "9f2c1b40-aaaa")).to eq("support-harvest-9f2c1b40")
    expect(g.clone_id_for("support", "1111-2222")).to eq("support-harvest-11112222")
  end
end
# Harvest probe Implementation Plan

> **Status: removed (2026-10-17).** Built, piloted on staging Época, then deleted. Store tools need a backend chat (achei-b2b `require_chat!`), so probe replays hit 404 on both sides and every case came out `comparable`; with 3 cases the judge also needed a double no-skill run to beat run-to-run noise. Skill value has to be measured on real traffic. The Harvest fixes found during the pilot stay (miner provider, synthetic-session skip, open-candidate dedup, re-gate of parked candidates, Studio visibility).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A harvest candidate skill must prove it *helps* the conversation it was mined from, not just that it breaks nothing.

**Architecture:** The eval gate (`Insika::Harvest::Gate`) already builds a clone of the agent. Before installing the candidate skill, the clone replays the origin session's customer turns ("before"). The gate then installs the skill and runs the usual golden replay. If the golden replay passes, it replays the same turns again ("after"). The existing pairwise judge (`Insika::Evals::Pairwise#compare_texts`, anonymous and run in both orders) compares after against before. The candidate passes only if at least one case is `better` and none is `worse`. When the agent has **no golden cases** (today: every store agent), the probe is the whole eval gate: the golden veto runs only when golden cases exist, and human approval stays mandatory either way. This is the "Probe" step of the Harness² paper (arXiv:2610.14224), built on what the gate already has.

**Why this shape (stress test, 2026-10-16):** `round1.db` holds 470 harvest runs for `agent-store-cacau-show` and zero candidates. Every run failed on a bare miner model ref; that was fixed in `6a56ea85`. The only golden case is a simulated persona, which the runner skips, so a probe that ran *after* the golden replay would never run. It has to gate on its own.

**Tech Stack:** Ruby, RSpec, the existing `Evals::Pairwise`, `Evals::JudgePanel`, `Safety::Detectors`.

**Spec:** This plan is the spec. Source idea: Harness² "Propose-Probe-Compose" (https://github.com/google-research/harness2). We only take Probe. Compose and per-turn refinement are out of scope.

## Global Constraints

- Opt-in per agent: `harvest: { probe: { enabled: true, max_cases: 3, max_turns: 4 } }` in the agent profile. When it is off, gate behavior and reports stay byte-for-byte the same as today.
- No new dependency, no new store, no new command.
- The probe runs only on the gate clone, never on the live agent.
- Transcripts sent to the judge go through `Insika::Safety::Detectors.redact` first, the same masking the miner uses.
- A missing ruler refuses with a named reason and never passes: probe on + no pairwise judge, or probe on + no origin turns.
- Defaults: `MAX_CASES = 3`, `MAX_TURNS = 4`.
- No golden cases + probe on → the probe alone decides. No golden cases + probe off → the existing "no golden cases" refusal, unchanged. Golden cases present → the golden veto runs first, then the probe.

## Review Focus

1. **Origin session deleted by retention.** Probe is on but no turns can be built. The candidate parks at `gated` with `probe_no_cases` and does not slip through. Covered in Task 3.
2. **Judge split, unknown or order-dependent.** These count as "not better". A probe where every case is `comparable` fails with a named reason. Covered in Task 1.
3. **A replayed turn errors halfway.** The transcript holds only the turns that ran. The comparison still happens and the gate does not crash. Covered in Task 2.
4. **Customer PII in the judge prompt.** A phone number or CPF in a customer turn is redacted before it reaches the judge. Covered in Task 2.
5. **Golden replay fails.** The probe "after" pass is not run, so no judge cost is spent on a candidate that already lost. Covered in Task 2.
6. **Agent with no golden cases.** With the probe on, it gates on the probe alone and the baseline refusals do not fire. With the probe off, it still refuses as today. Covered in Task 2.

Known limit, documented in Task 4 and not solved here: the clone calls the same live tools that the golden replay calls today. Replaying a real customer turn that triggers a write tool hits that tool. `max_turns` caps the exposure, and that is why the probe is opt-in.

---

### Task 1: `Harvest::Probe` (pure functions: cases and verdict)

**Files:**
- Create: `lib/insika/harvest/probe.rb`
- Modify: `lib/insika/harvest.rb` (add `require_relative "harvest/probe"` next to the other `harvest/*` requires; check how `gate.rb` is required and copy that style)
- Test: `spec/insika/harvest/probe_spec.rb`

**Interfaces:**
- Produces:
  - `Insika::Harvest::Probe.cases(sessions, evidence_turns:, max_cases: MAX_CASES, max_turns: MAX_TURNS) -> [[String]]`. `sessions` is an array of message arrays (`[{ "role" =>, "content" => }]`).
  - `Insika::Harvest::Probe.verdict(outcomes) -> Hash` with `"passed"`, `"reason"`, `"better"`, `"comparable"`, `"worse"`, `"cases"`, `"verdicts"`. `outcomes` is an array of `Evals::Pairwise::Verdict` or `nil`.

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Harvest::Probe do
  def msg(role, content) = { "role" => role, "content" => content }

  def verdict(outcome, reason: "r")
    Insika::Evals::Pairwise::Verdict.new(outcome: outcome, reason: reason, vs: "agent",
                                         judges: [outcome], order_dependent: false)
  end

  describe ".cases" do
    let(:session) do
      [msg("user", "oi"), msg("assistant", "olá"), msg("user", "tem pix?"),
       msg("assistant", "não sei"), msg("user", "e boleto?"), msg("assistant", "sim")]
    end

    it "keeps the customer turns up to the last evidence turn" do
      expect(described_class.cases([session], evidence_turns: [3])).to eq([["oi", "tem pix?"]])
    end

    it "uses the whole session when there is no usable evidence turn" do
      expect(described_class.cases([session], evidence_turns: [])).to eq([["oi", "tem pix?", "e boleto?"]])
      expect(described_class.cases([session], evidence_turns: [99])).to eq([["oi", "tem pix?", "e boleto?"]])
    end

    it "caps turns per case and the number of cases" do
      cases = described_class.cases([session] * 5, evidence_turns: [], max_cases: 2, max_turns: 1)
      expect(cases).to eq([["oi"], ["oi"]])
    end

    it "drops sessions with no customer text" do
      expect(described_class.cases([[msg("assistant", "olá")], []], evidence_turns: [])).to eq([])
    end
  end

  describe ".verdict" do
    it "passes with at least one better and no worse" do
      v = described_class.verdict([verdict("better"), verdict("comparable")])
      expect(v).to include("passed" => true, "reason" => nil, "better" => 1, "comparable" => 1, "worse" => 0, "cases" => 2)
    end

    it "fails on any worse, naming the judge's reason" do
      v = described_class.verdict([verdict("better"), verdict("worse", reason: "inventou preço")])
      expect(v["passed"]).to be(false)
      expect(v["reason"]).to match(/probe_worse.*inventou preço/)
    end

    it "fails when nothing got better — split, unknown and nil count as not better" do
      v = described_class.verdict([verdict("comparable"), verdict("split"), verdict("unknown"), nil])
      expect(v["passed"]).to be(false)
      expect(v["reason"]).to match(/probe_no_gain/)
      expect(v["comparable"]).to eq(4)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/insika/harvest/probe_spec.rb`
Expected: FAIL with `uninitialized constant Insika::Harvest::Probe`

- [ ] **Step 3: Write minimal implementation**

```ruby
# frozen_string_literal: true

module Insika
  module Harvest
    # The probe half of the eval gate: does the candidate skill HELP the
    # conversation it was mined from? The golden replay only proves it breaks
    # nothing. The gate replays the origin's customer turns on the clone
    # without the skill and then with it, and the pairwise judge compares the
    # two. Pure functions here; the replay lives in Gate.
    module Probe
      MAX_CASES = 3
      MAX_TURNS = 4

      # sessions: [[{ "role", "content" }]] -> [[customer text]]. A session is
      # cut at its last evidence turn (the moment the miner pointed at), or
      # kept whole when no evidence index fits it.
      def self.cases(sessions, evidence_turns:, max_cases: MAX_CASES, max_turns: MAX_TURNS)
        sessions.filter_map do |messages|
          messages = Array(messages)
          last = Array(evidence_turns).map(&:to_i).select { |t| t < messages.size }.max
          scope = last ? messages[0..last] : messages
          turns = scope.select { |m| m["role"].to_s == "user" }
                       .map { |m| m["content"].to_s.strip }
                       .reject(&:empty?)
                       .first(max_turns)
          turns unless turns.empty?
        end.first(max_cases)
      end

      # [Pairwise::Verdict | nil] -> Hash. A veto like the golden gate: any
      # `worse` fails, and so does a probe where nothing got better.
      # split/unknown/nil express no preference, so they count as comparable.
      def self.verdict(outcomes)
        better = outcomes.select { |v| v&.outcome == Insika::Evals::Pairwise::BETTER }
        worse = outcomes.select { |v| v&.outcome == Insika::Evals::Pairwise::WORSE }
        reason = if worse.any? then "probe_worse: #{worse.first.reason}"
                 elsif better.empty? then "probe_no_gain: no case improved over the agent without the skill"
                 end
        { "passed" => reason.nil?, "reason" => reason, "better" => better.size,
          "comparable" => outcomes.size - better.size - worse.size, "worse" => worse.size,
          "cases" => outcomes.size,
          "verdicts" => outcomes.map { |v| v && { "outcome" => v.outcome, "reason" => v.reason } } }
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/insika/harvest/probe_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/insika/harvest/probe.rb lib/insika/harvest.rb spec/insika/harvest/probe_spec.rb
git commit -m "feat(harvest): probe cases and verdict"
```

---

### Task 2: The gate runs the probe on its clone

**Files:**
- Modify: `lib/insika/harvest/gate.rb`
- Test: `spec/insika/harvest/gate_spec.rb` (new `describe "the probe"` block at the end)

**Interfaces:**
- Consumes: `Probe.verdict` from Task 1. `Insika::Evals::Pairwise#compare_texts(ours:, theirs:)` and `Pairwise.transcript(user_turns, turns)`, both existing.
- Produces:
  - `Gate.new(..., pairwise_factory: nil)`: a lambda returning an `Evals::Pairwise` or nil.
  - `Gate#score(agent_id:, skill:, run_id:, probe_cases: [])`.
  - `Gate::Report` gains a `probe` member (Hash from `Probe.verdict`, or nil), and `to_h` adds `"probe"`.

- [ ] **Step 1: Write the failing tests**

Append inside the top-level `RSpec.describe`. `GateTransportDouble` keys its script by the text after `"eval-"`. Probe conversations use ids starting with `probe-`, so the double answers them with its default `"ok"`. For the probe we need a transport that answers by phase, so add this double next to the other one:

```ruby
  # Answers probe turns by phase (conv id ends in -before / -after) and
  # golden turns like GateTransportDouble. Records every message it saw.
  class ProbeTransportDouble < GateTransportDouble
    attr_reader :messages_seen

    def initialize(script, before: "não sei", after: "aceitamos pix", error_after: false)
      super(script)
      @before = before
      @after = after
      @error_after = error_after
      @messages_seen = []
    end

    def turn(agent:, conv:, message:)
      @messages_seen << [conv, message]
      return super unless conv.start_with?("probe-")

      @agents_seen << agent
      error = @error_after && conv.end_with?("-after") ? "boom" : nil
      text = conv.end_with?("-before") ? @before : @after
      Insika::Evals::TurnOutcome.new(
        result: Insika::Evals::TurnResult.new(output_text: text, tool_calls: [], error: error),
        ttfb: 1.0, total: 2.0, usage: nil
      )
    end
  end
```

```ruby
  describe "the probe" do
    let(:golden_ok) { { "quotes-freight" => { text: "R$ 20", tools: ["shipping_quote"] } } }
    let(:asked) { [] }

    # A scripted pairwise judge: says the side containing `winner_text` wins.
    def pairwise(winner_text:, sink:)
      ask = lambda do |prompt|
        sink << prompt
        a = prompt[/CONVERSATION A:\n(.*?)\n\s*CONVERSATION B:/m, 1].to_s
        { "winner" => a.include?(winner_text) ? "A" : "B", "reason" => "resolveu" }.to_json
      end
      Insika::Evals::Pairwise.new(asks: [ask])
    end

    def probe_gate(transport, pairwise_factory:)
      described_class.new(profiles: profiles, agent_files: agent_files, goldens: goldens,
                          baselines: baselines, skill_store: skill_store,
                          skill_catalog: skill_catalog, transport_factory: -> { transport },
                          pairwise_factory: pairwise_factory)
    end

    before do
      seed_case
      baseline!("quotes-freight" => { "pass" => true, "score" => nil })
    end

    it "passes when the skill makes the origin conversation better" do
      transport = ProbeTransportDouble.new(golden_ok)
      judge = pairwise(winner_text: "aceitamos pix", sink: asked)
      report = probe_gate(transport, pairwise_factory: -> { judge })
               .score(agent_id: "support", skill: candidate, run_id: "r1", probe_cases: [["tem pix?"]])
      expect(report.passed).to be(true)
      expect(report.probe).to include("passed" => true, "better" => 1)
      expect(report.to_h["probe"]).to eq(report.probe)
    end

    it "rejects when the skill makes it worse" do
      transport = ProbeTransportDouble.new(golden_ok)
      judge = pairwise(winner_text: "não sei", sink: asked)
      report = probe_gate(transport, pairwise_factory: -> { judge })
               .score(agent_id: "support", skill: candidate, run_id: "r1", probe_cases: [["tem pix?"]])
      expect(report.passed).to be(false)
      expect(report.reason).to match(/probe_worse/)
    end

    it "replays before without the skill and after with it, on the clone only" do
      transport = ProbeTransportDouble.new(golden_ok)
      probe_gate(transport, pairwise_factory: -> { pairwise(winner_text: "aceitamos pix", sink: asked) })
        .score(agent_id: "support", skill: candidate, run_id: "r1", probe_cases: [["tem pix?"]])
      convs = transport.messages_seen.map(&:first)
      expect(convs.first).to end_with("-before")
      expect(convs.last).to end_with("-after")
      expect(transport.agents_seen.uniq).to eq(["support-harvest-r1"])
    end

    it "skips the after pass and the judge when the golden replay regresses" do
      transport = ProbeTransportDouble.new({ "quotes-freight" => { text: "não sei", tools: [] } })
      report = probe_gate(transport, pairwise_factory: -> { pairwise(winner_text: "x", sink: asked) })
               .score(agent_id: "support", skill: candidate, run_id: "r1", probe_cases: [["tem pix?"]])
      expect(report.passed).to be(false)
      expect(report.probe).to be_nil
      expect(transport.messages_seen.map(&:first)).not_to include(a_string_ending_with("-after"))
      expect(asked).to be_empty
    end

    it "refuses when probe cases are given but no pairwise judge is configured" do
      report = probe_gate(ProbeTransportDouble.new(golden_ok), pairwise_factory: -> { nil })
               .score(agent_id: "support", skill: candidate, run_id: "r1", probe_cases: [["tem pix?"]])
      expect(report.passed).to be(false)
      expect(report.reason).to match(/no pairwise judge/)
    end

    it "still judges when an after turn errors, on the turns that ran" do
      transport = ProbeTransportDouble.new(golden_ok, error_after: true)
      report = probe_gate(transport, pairwise_factory: -> { pairwise(winner_text: "aceitamos pix", sink: asked) })
               .score(agent_id: "support", skill: candidate, run_id: "r1", probe_cases: [["tem pix?", "e boleto?"]])
      expect(report.probe).not_to be_nil
      expect(transport.messages_seen.count { |c, _| c.end_with?("-after") }).to eq(1)
    end

    it "redacts customer PII before the judge sees it" do
      transport = ProbeTransportDouble.new(golden_ok)
      probe_gate(transport, pairwise_factory: -> { pairwise(winner_text: "aceitamos pix", sink: asked) })
        .score(agent_id: "support", skill: candidate, run_id: "r1",
               probe_cases: [["meu cpf é 123.456.789-09, tem pix?"]])
      expect(asked.join).not_to include("123.456.789-09")
    end

    it "gates on the probe alone when the agent has no golden cases" do
      goldens.delete("quotes-freight")
      baselines.delete("support")
      transport = ProbeTransportDouble.new({})
      report = probe_gate(transport, pairwise_factory: -> { pairwise(winner_text: "aceitamos pix", sink: asked) })
               .score(agent_id: "support", skill: candidate, run_id: "r1", probe_cases: [["tem pix?"]])
      expect(report.passed).to be(true)
      expect(report.cases).to eq(0)
      expect(report.probe).to include("better" => 1)
    end

    it "still refuses an agent with no golden cases when the probe is off" do
      goldens.delete("quotes-freight")
      report = probe_gate(ProbeTransportDouble.new({}), pairwise_factory: -> { nil })
               .score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(report.passed).to be(false)
      expect(report.reason).to match(/no golden cases/)
    end

    it "leaves the report unchanged when no probe cases are given" do
      report = gate(script: golden_ok).first.score(agent_id: "support", skill: candidate, run_id: "r1")
      expect(report.passed).to be(true)
      expect(report.probe).to be_nil
    end
  end
```

Before writing the PII test, check that `Insika::Safety::Detectors.redact("meu cpf é 123.456.789-09")` masks the CPF in the built-in corpus (`bundle exec ruby -Ilib -e 'require "insika"; p Insika::Safety::Detectors.redact("meu cpf é 123.456.789-09")'`). If CPF is not covered, use a value the corpus does mask, such as a phone number, and keep the test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/insika/harvest/gate_spec.rb -e "the probe"`
Expected: FAIL with `unknown keyword: :pairwise_factory`

- [ ] **Step 3: Implement**

In `lib/insika/harvest/gate.rb`:

1. Add `:probe` to `Report` and to `to_h`:

```ruby
      Report = Data.define(:candidate_id, :passed, :reason, :cases, :passed_cases,
                           :baseline_cases, :regressions, :report, :tokens, :cached, :probe) do
        def to_h
          { "candidate_id" => candidate_id, "passed" => passed, "reason" => reason,
            "cases" => cases, "passed_cases" => passed_cases, "baseline_cases" => baseline_cases,
            "regressions" => regressions, "report" => report, "tokens" => tokens,
            "cached" => cached, "probe" => probe }
        end
      end
```

2. Add `pairwise_factory: nil` to `initialize` (store it as `@pairwise_factory`).

3. Replace `score`. The golden refusals move into `golden_refusal` with their messages unchanged, and run only when golden cases exist:

```ruby
      def score(agent_id:, skill:, run_id:, probe_cases: [])
        cases = @goldens.for_agent(agent_id)
        if cases.empty? && probe_cases.empty?
          return refusal(skill, "the agent has no golden cases — nothing to gate against")
        end

        baseline = judge = nil
        if cases.any?
          baseline = @baselines.get(agent_id)
          judge = @judge_factory&.call
          refused = golden_refusal(agent_id, skill, baseline, judge)
          return refused if refused
        end

        pairwise = nil
        if probe_cases.any?
          pairwise = @pairwise_factory&.call
          if pairwise.nil?
            return refusal(skill, "the probe is on but no pairwise judge is configured — " \
                                  "configure the judge panel (Studio → Settings → Evals) or turn " \
                                  "`harvest.probe.enabled` off for '#{agent_id}'")
          end
        end

        clone_id = clone_id_for(agent_id, run_id)
        tag = run_id.to_s.delete("-")[0, 8]
        begin
          profile = build_clone(agent_id, clone_id)
          before = converse_all(clone_id, probe_cases, tag, "before")
          install_skill(profile, clone_id, skill)
          # No golden cases: nothing to veto, the probe below decides alone.
          report = if cases.any?
                     verdict(skill, replay(cases, clone_id, judge), baseline, @tolerance)
                   else
                     Report.new(candidate_id: skill["name"], passed: true, reason: nil, cases: 0,
                                passed_cases: 0, baseline_cases: 0, regressions: [], report: nil,
                                tokens: nil, cached: nil, probe: nil)
                   end
          return report unless report.passed && probe_cases.any?

          after = converse_all(clone_id, probe_cases, tag, "after")
          probe = Probe.verdict(before.zip(after).map { |b, a| pairwise.compare_texts(ours: a, theirs: b) })
          report.with(passed: probe["passed"], reason: probe["reason"], probe: probe)
        rescue StandardError => e
          refusal(skill, "gate failed to run: #{e.class}: #{e.message}")
        ensure
          destroy_clone(clone_id)
        end
      end
```

3b. `golden_refusal` (private) holds the three existing refusals, with the same messages copied verbatim from the current `score`:

```ruby
      # The P18 refusals — only meaningful when there ARE golden cases.
      # -> Report | nil
      def golden_refusal(agent_id, skill, baseline, judge)
        if baseline.nil?
          return refusal(skill, "no recorded baseline for '#{agent_id}' — " \
                                "run `insika evals:baseline import` or record one before gating")
        end
        if passing_cases(baseline).zero?
          return refusal(skill, "the recorded baseline for '#{agent_id}' has no PASSING case " \
                                "(#{baseline_size(baseline)} recorded, all failing) — nothing could " \
                                "regress, so every candidate would pass. Fix the agent or the cases, " \
                                "then re-record the baseline from a green run")
        end
        return nil unless judge.nil? && judged?(baseline)

        refusal(skill, "the recorded baseline for '#{agent_id}' carries judge scores but no " \
                       "judge is configured — a rubric'd case with no verdict counts as a " \
                       "PASS, so every candidate would beat it. Configure the judge panel " \
                       "(Studio → Settings → Evals, or `settings[\"evals\"][\"judges\"]`) or " \
                       "re-record the baseline without one")
      end
```

4. Split `build_clone` into a clone step and a skill step (same lines, two methods):

```ruby
      def build_clone(agent_id, clone_id)
        profile = @profiles.fetch(agent_id) ||
                  (raise Insika::NotFoundError, "agent '#{agent_id}' not configured")

        @profiles.put(profile.with(id: clone_id))
        current_files(agent_id).each { |name, body| @agent_files.write(clone_id, name, body) }
        profile
      end

      # D7: the skill lands into the clone's AGENT-scoped SkillStore (the
      # store position IS the identity), and the clone's profile `skills`
      # gains the name — so the clone's catalog serves it and the model can
      # load_skill it.
      def install_skill(profile, clone_id, skill)
        name = skill["name"].to_s
        @skill_store.write(name, skill["body"].to_s, agent: clone_id)
        enabled = profile.skills.nil? ? nil : (Array(profile.skills).map(&:to_s) | [name])
        @profiles.put(profile.with(id: clone_id, skills: enabled))
        @skill_catalog.reload
      end
```

5. Add the replay helpers (private):

```ruby
      # One conversation per probe case, on a fresh conv id per phase. Stops a
      # case at its first errored turn — the judge reads what ran. Redacted
      # before it leaves for the judge, the same masking the miner uses.
      def converse_all(clone_id, probe_cases, tag, phase)
        return [] if probe_cases.empty?

        transport = @transport_factory.call
        probe_cases.each_with_index.map do |turns, i|
          conv = "probe-#{tag}-#{i}-#{phase}"
          ran = []
          turns.each do |message|
            ran << transport.turn(agent: clone_id, conv: conv, message: message).result
            break if ran.last.error
          end
          Insika::Safety::Detectors.redact(Insika::Evals::Pairwise.transcript(turns, ran)).first
        end
      end
```

6. Pass `probe: nil` in both `Report.new` calls (`verdict` and `refusal`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/insika/harvest/gate_spec.rb spec/insika/harvest/probe_spec.rb`
Expected: PASS (the old gate examples included)

- [ ] **Step 5: Run every spec that builds a `Gate::Report`**

Run: `grep -rln "Gate::Report.new" spec lib` and add `probe: nil` to each `Report.new` it lists (at least `spec/insika/commands/gate_harvest_spec.rb`).
Then: `bundle exec rspec spec/insika/harvest spec/insika/commands/gate_harvest_spec.rb spec/insika/commands/promote_harvest_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/insika/harvest/gate.rb spec/insika/harvest/gate_spec.rb spec/insika/commands/gate_harvest_spec.rb
git commit -m "feat(harvest): gate probes the origin conversation before and after the skill"
```

---

### Task 3: `GateHarvest` builds probe cases from the profile and origin sessions

**Files:**
- Modify: `lib/insika/commands/gate_harvest.rb`
- Modify: `config/deployment.rb:397-414` (`HARVEST_GATE`) and `config/deployment.rb:436-440` (`GateHarvest.new`)
- Test: `spec/insika/commands/gate_harvest_spec.rb`

**Interfaces:**
- Consumes: `Probe.cases` (Task 1), `Gate#score(..., probe_cases:)` (Task 2), `AgentProfile#harvest` (a stringified Hash or nil), `SessionStore#find(id)&.messages`.
- Produces: `GateHarvest.new(..., profiles: nil, session_store: nil)`. With both nil, behavior is unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `spec/insika/commands/gate_harvest_spec.rb`. Read the file's existing `create_candidate` helper first and reuse it. The calls below assume it accepts `origin:` and `evidence_turns:`; if it does not, add those two keywords to it.

```ruby
  describe "the probe" do
    let(:session_store) { Insika::SessionStore.new(store: backend) }
    let(:config_store) { Insika::ConfigStore.new(store: backend) }
    let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
    let(:seen) { [] }

    subject(:handler) do
      described_class.new(harvest_store: harvest_store, gate: gate, conversion_gate: conversion_gate,
                          criterion: criterion, event_stream: stream,
                          profiles: profiles, session_store: session_store)
    end

    def seed_profile(probe:)
      profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m", provider: :deepseek,
                                              harvest: { "probe" => probe }))
    end

    def seed_origin(id = "acme:sess_1")
      session_store.create(id: id, vars: { "agent" => "store-support" })
      session_store.append_messages(id, [{ "role" => "user", "content" => "tem pix?" },
                                         { "role" => "assistant", "content" => "não sei" }])
    end

    before do
      allow(gate).to receive(:score) do |agent_id:, skill:, run_id:, probe_cases: []|
        seen << probe_cases
        Insika::Harvest::Gate::Report.new(candidate_id: skill["name"], passed: true, reason: nil,
                                          cases: 1, passed_cases: 1, baseline_cases: 1,
                                          regressions: [], report: {}, tokens: nil, cached: nil, probe: nil)
      end
      allow(conversion_gate).to receive(:call).and_return(conversion(passed: true))
    end

    it "sends the origin's customer turns when the agent turned the probe on" do
      seed_profile(probe: { "enabled" => true })
      seed_origin
      c = create_candidate(origin: ["acme:sess_1"], evidence_turns: [1])
      handler.call(cmd(candidate_id: c.id))
      expect(seen).to eq([[["tem pix?"]]])
    end

    it "sends no probe cases when the probe is off" do
      seed_profile(probe: { "enabled" => false })
      seed_origin
      c = create_candidate(origin: ["acme:sess_1"])
      handler.call(cmd(candidate_id: c.id))
      expect(seen).to eq([[]])
    end

    it "parks the candidate when the probe is on but the origin is gone" do
      seed_profile(probe: { "enabled" => true })
      c = create_candidate(origin: ["acme:deleted"])
      result = handler.call(cmd(candidate_id: c.id))
      expect(result.status).to eq("gated")
      expect(result.eval_gate).to include("passed" => false, "reason" => "probe_no_cases")
      expect(seen).to be_empty
    end
  end
```

Check `AgentProfile.build` accepts `harvest:`. It is a profile member (`lib/insika/agent_profile.rb:275`). If `build` does not take it, use `profile.with(harvest: {...})`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/insika/commands/gate_harvest_spec.rb -e "the probe"`
Expected: FAIL with `unknown keyword: :profiles`

- [ ] **Step 3: Implement**

In `lib/insika/commands/gate_harvest.rb`:

```ruby
      def initialize(harvest_store:, gate:, conversion_gate:, criterion: nil, event_stream:,
                     profiles: nil, session_store: nil)
        # ... existing assignments ...
        @profiles = profiles
        @session_store = session_store
      end
```

In `call`, after the budget check and before `skill = ...`:

```ruby
        probe_cases = probe_cases_for(candidate)
        if probe_cases == :no_cases
          return @harvest_store.attach_gate(
            candidate.id,
            eval_gate: { "passed" => false, "reason" => "probe_no_cases" },
            conversion_gate: { "passed" => false, "reason" => "probe_no_cases" },
            criterion_sha: nil
          )
        end
```

Replace the `@gate.score` call so the old 3-keyword shape is kept when the probe is off (existing doubles keep working):

```ruby
        probe_kw = probe_cases.empty? ? {} : { probe_cases: probe_cases }
        eval_report = @gate.score(agent_id: candidate.agent, skill: skill,
                                  run_id: candidate.run_id, **probe_kw)
```

Note: with `probe_kw` empty for "off", the "sends no probe cases" test sees the double's default `[]`. That is the intended behavior.

Private helpers:

```ruby
      # -> [] (probe off), :no_cases (on, but nothing to replay — parks), or
      # the customer turns to replay.
      def probe_cases_for(candidate)
        config = probe_config(candidate.agent)
        return [] unless config

        sessions = Array(candidate.origin).filter_map { |sid| @session_store.find(sid)&.messages&.to_a }
        cases = Insika::Harvest::Probe.cases(
          sessions, evidence_turns: candidate.evidence_turns,
          max_cases: (config["max_cases"] || Insika::Harvest::Probe::MAX_CASES).to_i,
          max_turns: (config["max_turns"] || Insika::Harvest::Probe::MAX_TURNS).to_i
        )
        cases.empty? ? :no_cases : cases
      end

      def probe_config(agent)
        return nil unless @profiles && @session_store

        config = (@profiles.fetch(agent)&.harvest || {})["probe"]
        config.is_a?(Hash) && config["enabled"] ? config : nil
      end
```

In `config/deployment.rb`, add to `HARVEST_GATE`:

```ruby
      pairwise_factory: -> { Insika::Evals::JudgePanel.pairwise((SETTINGS_STORE.get || {})["evals"], llm: LLM_CONTEXT)&.first },
```

and to the `:gate_harvest` registration:

```ruby
      profiles: PROFILE_SOURCE, session_store: SESSION_STORE,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/insika/commands/gate_harvest_spec.rb spec/insika/harvest spec/insika/deployment_wiring_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/insika/commands/gate_harvest.rb config/deployment.rb spec/insika/commands/gate_harvest_spec.rb
git commit -m "feat(harvest): gate_harvest feeds origin turns to the probe when the agent opts in"
```

---

### Task 4: Docs, changelog, full suite

**Files:**
- Modify: `docs/HARVEST.md` (section `## The double gate`, and `## The honest limits`)
- Modify: `CHANGELOG.md` (`## [Unreleased]` → `### Added`)

- [ ] **Step 1: Add to `docs/HARVEST.md`, at the end of `## The double gate`**

```markdown
### The probe (opt-in)

The golden replay proves a candidate breaks nothing. It does not prove the
candidate fixes the conversation it was mined from. With
`harvest: { probe: { enabled: true } }` on the agent, the gate also replays
the origin session's customer turns (up to the last evidence turn, at most
`max_turns: 4` per case and `max_cases: 3` cases) on the clone twice: once
before the skill is installed and once after. The pairwise judge
(anonymous, both orders, see [Evals](EVALS.md)) compares the two. The
candidate passes only if at least one case got `better` and none got
`worse`. Transcripts are redacted before the judge reads them.

An agent with no golden cases is gated by the probe alone. That is the
point of the probe: the origin conversation is a test case nobody had to
write. With golden cases, the golden veto runs first and the probe second.
A human approves every promotion either way.

Refusals, never passes: probe on with no pairwise judge configured
(the gate refuses), probe on with no origin turns left (the candidate
parks at `gated` with `probe_no_cases`). The after pass and its judge
calls run only when the golden replay passed. Cost per candidate:
2 × cases × turns agent turns, plus 2 judge calls per judge per case.

Idea from Harness² (Google Research, arXiv:2610.14224), "Probe" step.
```

- [ ] **Step 2: Add to `## The honest limits`**

```markdown
- **The probe replays real customer turns against live tools.** The clone
  has the agent's tools, as in the golden replay. A customer turn that
  leads to a write tool calls it. `max_turns` caps the exposure; keep the
  probe off for agents whose write tools touch external systems without a
  confirmation step.
```

- [ ] **Step 3: Add to `CHANGELOG.md` under `## [Unreleased]` → `### Added`**

```markdown
- Harvest gate probe (opt-in, `harvest.probe.enabled`): a candidate skill must also win a pairwise comparison on its origin conversation, replayed on the gate clone without and with the skill.
```

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS, with the same pending count as on `staging` before this branch.

- [ ] **Step 5: Commit**

```bash
git add docs/HARVEST.md CHANGELOG.md
git commit -m "docs(harvest): the probe step"
```

---

### Task 5: Pilot on Cacau Show (decides if the probe stays)

No code. This task answers "is it useful?" with real candidates. It runs after Tasks 1-4 are deployed.

**Files:**
- Modify: `packs/agent-store-cacau-show/agent.config.json` (the `harvest` block)

- [ ] **Step 1: Turn the probe on for Cacau Show**

```json
  "harvest": {
    "enabled": true,
    "probe": { "enabled": true, "max_cases": 3, "max_turns": 4 },
    "miner": {
      "model": "deepseek/deepseek-v4-flash",
      "budget": { "tokens": 40000 }
    }
  },
```

The model ref now carries its provider explicitly. The code fallback from `6a56ea85` also covers the bare form.

- [ ] **Step 2: Confirm the miner now produces candidates**

After deploy, open Studio → Harvest for `agent-store-cacau-show`. Within a day, runs must show `completed` or `no_candidates`. A `failed` run stops the pilot; read its `error` first.

- [ ] **Step 3: Collect 10 gated candidates**

For each candidate: the probe verdict (`eval_gate.probe`: better/comparable/worse, `order_dependent`) and the operator's own call, made **before** reading the verdict: "would I approve this skill?" Record both in a table in this plan.

- [ ] **Step 4: Decide with these numbers**

Keep the probe if **all** hold:
- Agreement between the probe and the operator on at least 7 of 10.
- At most 3 of 10 candidates where every case came out `comparable`, `split` or order-dependent. More than that means the judge is not telling the two versions apart.
- No case where the probe passed a skill the operator judged harmful.

Otherwise turn `probe.enabled` off and record why here. Watch one bias: the judge (`deepseek-v4-flash`) is the same model as the agent. If the probe prefers longer replies, configure a different judge model before discarding it.

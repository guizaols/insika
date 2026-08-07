# frozen_string_literal: true

require "spec_helper"

# RFC-0013 phase C, the two commands that move a run from "here is a report" to
# "the prompt changed". The cases that matter are the refusals: writing to an
# agent's instructions is opt-in, bounded, and never applied from a stale snapshot.
RSpec.describe "refinement phase C commands" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:agent_files) { Insika::AgentFileStore.new(config_store: config_store) }
  let(:runs) { Insika::RefinementStore.new(store: backend) }
  let(:events) { Insika::EventStream.new }

  BODY = "# Tools\n\nUse shipping_quote to quote freight.\n#{"Be brief and warm.\n" * 20}"
  AFTER = "Use shipping_quote to quote freight. Ask for the CEP first."

  # Passes or fails on command, and records what it was asked to score. The real
  # gate has its own spec; here the question is what the COMMANDS do with a verdict.
  class GateDouble
    attr_reader :scored

    # `passed` may be a boolean (every candidate scores the same) or a lambda over the
    # candidate, which is what a PANEL spec needs to make one member win.
    def initialize(passed: true, tokens: nil, passed_cases: nil)
      @passed = passed
      @tokens = tokens
      @passed_cases = passed_cases
      @scored = []
    end

    def score(agent_id:, candidate:, run_id:, tolerance: nil)
      @scored << { agent_id: agent_id, candidate: candidate, tolerance: tolerance }
      passed = @passed.respond_to?(:call) ? @passed.call(candidate) : @passed
      cases = @passed_cases.respond_to?(:call) ? @passed_cases.call(candidate) : (passed ? 1 : 0)
      Insika::Refinement::Gate::Report.new(
        candidate_id: candidate.id, passed: passed,
        reason: passed ? nil : "1 regression(s): quotes (pass→fail)",
        cases: 1, passed_cases: cases, baseline_cases: 1,
        regressions: passed ? [] : [{ "id" => "quotes", "kind" => "pass→fail" }], report: {},
        tokens: @tokens.respond_to?(:call) ? @tokens.call(candidate) : @tokens
      )
    end
  end

  def seed(mode: "propose", files: ["TOOLS.md"])
    refinement = { "mode" => mode, "files" => files }.compact
    profiles.put(Insika::AgentProfile.build(id: "support", model: "m", refinement: refinement))
    agent_files.write("support", "TOOLS.md", BODY)
  end

  # A run in :completed — the state a gate starts from.
  def completed_run
    run = runs.create(agent_id: "support", window: { "last_sessions" => 200 })
    runs.complete(run.id, findings: [{ "kind" => "tool_error", "count" => 4 }])
  end

  def edits(before: "Use shipping_quote to quote freight.", after: AFTER, file: "TOOLS.md")
    [{ "file" => file, "op" => "replace", "before" => before, "after" => after,
       "addresses" => ["tool_error:shipping_quote"] }]
  end

  def gate_command(gate = GateDouble.new, proposer_factory: nil, resolver: nil)
    [Insika::Commands::GateRefinement.new(profiles: profiles, refinement_store: runs,
                                          agent_file_store: agent_files, gate: gate,
                                          event_stream: events,
                                          proposer_factory: proposer_factory,
                                          resolver: resolver), gate]
  end

  # A proposer whose model answers with `reply`, recording what it was shown.
  def proposer_factory(reply, model: "deepseek/deepseek-chat", seen: [])
    lambda { |config|
      seen << { config: config }
      Insika::Refinement::Proposer.new(ask: lambda { |prompt|
        seen.last[:prompt] = prompt
        reply
      }, model: model)
    }
  end

  def resolve_command
    Insika::Commands::ResolveRefinement.new(profiles: profiles, refinement_store: runs,
                                            agent_file_store: agent_files, event_stream: events)
  end

  def dispatch(handler, payload)
    handler.call(Insika::Command.build(:gate_refinement, payload, transport: :http))
  end

  describe Insika::Commands::GateRefinement do
    before { seed }

    it "gates a valid candidate and parks the run on a human" do
      run = completed_run
      cmd, gate = gate_command
      gated = dispatch(cmd, { run_id: run.id, candidate: { "proposer" => "m", "edits" => edits } })

      expect(gated.status).to eq(:awaiting_approval)
      expect(gated.gate_passed?).to be(true)
      expect(gated.edits.size).to eq(1)
      expect(gate.scored.first[:agent_id]).to eq("support")
    end

    it "records a gate FAILURE as terminal, with the reason, and never asks a human" do
      run = completed_run
      cmd, = gate_command(GateDouble.new(passed: false))
      gated = dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } })

      expect(gated.status).to eq(:rejected)
      expect(gated).to be_terminal
      expect(gated.decision["by"]).to eq("gate")
      expect(gated.decision["note"]).to match(/pass→fail/)
    end

    # §3.8: `propose` and above are opt-in, explicitly. An absent config is a NO,
    # not "not configured yet".
    it "refuses an agent still in report mode" do
      seed(mode: "report")
      run = completed_run
      cmd, gate = gate_command
      expect { dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } }) }
        .to raise_error(Insika::ValidationError, /mode 'report'/)
      expect(gate.scored).to be_empty
    end

    # An ABSENT refinement block reads as report-only (§3.8) — which is permission to
    # read your own traffic, never permission to edit a prompt.
    it "refuses an agent with no refinement config at all" do
      profiles.put(Insika::AgentProfile.build(id: "support", model: "m"))
      run = completed_run
      cmd, gate = gate_command
      expect { dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } }) }
        .to raise_error(Insika::ValidationError, /mode 'report'/)
      expect(gate.scored).to be_empty
    end

    it "refuses an empty files allowlist — nothing is writable" do
      seed(files: [])
      run = completed_run
      cmd, = gate_command
      expect { dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } }) }
        .to raise_error(Insika::ValidationError, /empty refinement.files allowlist/)
    end

    # Neither is worth a provider bill: the gate's replay is real conversations.
    it "refuses a candidate whose every edit dropped, naming the reasons" do
      run = completed_run
      cmd, gate = gate_command
      expect { dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits(before: "gone") } }) }
        .to raise_error(Insika::ValidationError, /every edit was dropped.*no longer matches/m)
      expect(gate.scored).to be_empty
    end

    it "refuses to gate a run that is not completed" do
      run = runs.create(agent_id: "support")
      cmd, = gate_command
      expect { dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } }) }
        .to raise_error(ArgumentError, /is collecting, expected completed/)
    end

    # PR 3b: the model writes the candidate and the SAME bounds and the SAME gate
    # apply to it. Nothing about the path changes because a model was involved.
    describe "propose: true (the model writes the candidate)" do
      let(:reply) do
        JSON.generate({ "rationale" => "TOOLS.md never says the CEP is required.",
                        "edits" => edits })
      end

      it "proposes from the run's findings, gates it, and parks it on a human" do
        run = completed_run
        seen = []
        cmd, gate = gate_command(GateDouble.new, proposer_factory: proposer_factory(reply, seen: seen))
        gated = dispatch(cmd, { run_id: run.id, propose: true })

        expect(gated.status).to eq(:awaiting_approval)
        expect(gated.candidate["proposer"]).to eq("deepseek/deepseek-chat")
        expect(gate.scored.first[:candidate].edits.first.after).to eq(AFTER)
        expect(seen.first[:prompt]).to include("tool_error", "TOOLS.md")
      end

      # Money. A caller who simply forgot the candidate gets an error, never a
      # proposal AND a gate replay they did not ask for.
      it "refuses a missing candidate when propose was not asked for" do
        run = completed_run
        cmd, gate = gate_command(GateDouble.new, proposer_factory: proposer_factory(reply))
        expect { dispatch(cmd, { run_id: run.id }) }
          .to raise_error(Insika::ValidationError, /candidate is required.*propose: true/m)
        expect(gate.scored).to be_empty
      end

      it "refuses when no proposer is configured, instead of guessing a model" do
        run = completed_run
        cmd, gate = gate_command(GateDouble.new, proposer_factory: ->(_config) { nil })
        expect { dispatch(cmd, { run_id: run.id, propose: true }) }
          .to raise_error(Insika::ValidationError, /no proposer is configured/)
        expect(gate.scored).to be_empty
      end

      # The order matters: an empty allowlist is `mode: propose` with nothing turned
      # on, and finding that out AFTER paying for a proposal is the wrong order.
      it "refuses an empty allowlist before calling the model" do
        seed(files: [])
        run = completed_run
        seen = []
        cmd, = gate_command(GateDouble.new, proposer_factory: proposer_factory(reply, seen: seen))
        expect { dispatch(cmd, { run_id: run.id, propose: true }) }
          .to raise_error(Insika::ValidationError, /empty refinement.files allowlist/)
        expect(seen.first[:prompt]).to be_nil
      end

      # The model is upstream of every bound and none of them move for it.
      it "drops a proposed edit to a file outside the allowlist" do
        run = completed_run
        off_list = JSON.generate({ "edits" => edits(file: "SECRETS.md") })
        cmd, = gate_command(GateDouble.new, proposer_factory: proposer_factory(off_list))
        expect { dispatch(cmd, { run_id: run.id, propose: true }) }
          .to raise_error(Insika::ValidationError, /not on the refinement allowlist/)
      end

      it "drops a proposed edit whose anchor was invented" do
        run = completed_run
        invented = JSON.generate({ "edits" => edits(before: "Sempre peça o CEP.") })
        cmd, = gate_command(GateDouble.new, proposer_factory: proposer_factory(invented))
        expect { dispatch(cmd, { run_id: run.id, propose: true }) }
          .to raise_error(Insika::ValidationError, /no longer matches/)
      end

      it "shows the model only the allowlisted files" do
        agent_files.write("support", "AGENTS.md", "the persona, not up for editing")
        run = completed_run
        seen = []
        cmd, = gate_command(GateDouble.new, proposer_factory: proposer_factory(reply, seen: seen))
        dispatch(cmd, { run_id: run.id, propose: true })

        expect(seen.first[:prompt]).to include("TOOLS.md")
        expect(seen.first[:prompt]).not_to include("the persona, not up for editing")
      end

      it "refuses to propose in report mode without calling a model" do
        seed(mode: "report")
        run = completed_run
        seen = []
        cmd, = gate_command(GateDouble.new, proposer_factory: proposer_factory(reply, seen: seen))
        expect { dispatch(cmd, { run_id: run.id, propose: true }) }
          .to raise_error(Insika::ValidationError, /mode 'report'/)
        expect(seen).to be_empty
      end
    end

    # RFC-0013 §3.9 (phase D). The command's shape does not change: N models write N
    # candidates, the gate scores each, and the best SURVIVOR is the one proposal a
    # human is shown. What is new is what the RUN records — the whole panel, and what
    # it cost.
    describe "the proposer panel" do
      def panel_factory(*afters)
        lambda { |_config|
          afters.each_with_index.map do |after, i|
            Insika::Refinement::Proposer.new(
              model: "model-#{i}",
              ask: ->(_p) { JSON.generate({ "edits" => edits(after: after) }) }
            )
          end
        }
      end

      it "records every candidate and promotes the highest-scoring one" do
        run = completed_run
        gate = GateDouble.new(passed_cases: ->(c) { c.edits.first.after.include?("CEP") ? 3 : 1 })
        cmd, = gate_command(gate, proposer_factory: panel_factory("Be warm.", AFTER))
        gated = dispatch(cmd, { run_id: run.id, propose: true })

        expect(gate.scored.size).to eq(2)
        expect(gated.status).to eq(:awaiting_approval)
        expect(gated.candidate["proposer"]).to eq("model-1")
        expect(gated.panel.size).to eq(2)
        expect(gated.panel.map { |e| e["gate"]["passed_cases"] }).to eq([1, 3])
      end

      it "rejects the run when no member of the panel survived" do
        run = completed_run
        cmd, = gate_command(GateDouble.new(passed: false),
                            proposer_factory: panel_factory("Be warm.", AFTER))
        gated = dispatch(cmd, { run_id: run.id, propose: true })

        expect(gated.status).to eq(:rejected)
        expect(gated.panel.size).to eq(2)
        expect(gated.decision["note"]).to match(/pass→fail/)
      end

      # §3.9's honest objection, answered: a ceiling the operator sets, checked before
      # each expensive step. The candidates it could not afford are recorded as such,
      # never dropped in silence.
      it "stops gating at the configured token budget and records the cost" do
        profiles.put(Insika::AgentProfile.build(
                       id: "support", model: "m",
                       refinement: { "mode" => "propose", "files" => ["TOOLS.md"],
                                     "budget" => { "tokens" => 100 } }
                     ))
        run = completed_run
        gate = GateDouble.new(tokens: 150)
        cmd, = gate_command(gate, proposer_factory: panel_factory("Be warm.", AFTER))
        gated = dispatch(cmd, { run_id: run.id, propose: true })

        expect(gate.scored.size).to eq(1)
        expect(gated.cost["spent"]).to eq(150)
        expect(gated.panel.last["gate"]["reason"]).to include("token budget (100) was spent")
      end
    end

    # D2: the ONE path where a prompt changes with no human in the loop. Off by
    # default, and narrow when on.
    describe "mode: auto_apply" do
      def auto_seed(max_edits: nil)
        refinement = { "mode" => "auto_apply", "files" => ["TOOLS.md"] }
        refinement["auto_apply_max_edits"] = max_edits if max_edits
        profiles.put(Insika::AgentProfile.build(id: "support", model: "m", refinement: refinement))
        agent_files.write("support", "TOOLS.md", BODY)
      end

      it "applies a gate-passing candidate through the same versioned write a human gets" do
        auto_seed
        run = completed_run
        cmd, = gate_command(GateDouble.new, resolver: resolve_command)
        applied = dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } })

        expect(applied.status).to eq(:applied)
        expect(applied.decision["by"]).to eq("auto_apply")
        expect(agent_files.read("support", "TOOLS.md")).to include("Ask for the CEP first.")
        expect(agent_files.versions("support", "TOOLS.md").first["content"]).to eq(BODY)
      end

      # "Too big to apply unattended" and "wrong" are different verdicts. Collapsing
      # them would throw away a proposal the gate already paid to score.
      it "parks a diff over auto_apply_max_edits on a human instead of rejecting it" do
        auto_seed(max_edits: 1)
        run = completed_run
        two = edits + [{ "file" => "TOOLS.md", "op" => "append", "after" => "Always greet." }]
        cmd, = gate_command(GateDouble.new, resolver: resolve_command)
        gated = dispatch(cmd, { run_id: run.id, candidate: { "edits" => two } })

        expect(gated.status).to eq(:awaiting_approval)
        expect(agent_files.read("support", "TOOLS.md")).to eq(BODY)
      end

      it "never auto-applies what the gate refused" do
        auto_seed
        run = completed_run
        cmd, = gate_command(GateDouble.new(passed: false), resolver: resolve_command)
        gated = dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } })

        expect(gated.status).to eq(:rejected)
        expect(agent_files.read("support", "TOOLS.md")).to eq(BODY)
      end

      # A deployment that cannot apply must not record that it did.
      it "leaves the run awaiting approval when no resolver is wired" do
        auto_seed
        run = completed_run
        cmd, = gate_command(GateDouble.new)
        gated = dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } })

        expect(gated.status).to eq(:awaiting_approval)
        expect(agent_files.read("support", "TOOLS.md")).to eq(BODY)
      end

      it "does not auto-apply an agent in mode: propose" do
        run = completed_run
        cmd, = gate_command(GateDouble.new, resolver: resolve_command)
        gated = dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } })

        expect(gated.status).to eq(:awaiting_approval)
      end
    end

    it "emits proposed then gated, with counts and no file content" do
      run = completed_run
      cmd, = gate_command
      seen = []
      sub = events.subscribe
      Thread.new { sub.each { |e| seen << e } }
      dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } })
      sleep 0.05
      sub.close

      types = seen.map(&:type)
      expect(types).to include(:refinement_proposed, :refinement_gated)
      payload = JSON.generate(seen.map(&:data))
      expect(payload).not_to include("Ask for the CEP")
    end
  end

  describe Insika::Commands::ResolveRefinement do
    before { seed }

    def awaiting
      run = completed_run
      cmd, = gate_command
      dispatch(cmd, { run_id: run.id, candidate: { "edits" => edits } })
    end

    def resolve(payload)
      resolve_command.call(Insika::Command.build(:resolve_refinement, payload, transport: :http))
    end

    it "writes the edits on approval and versions the previous content" do
      run = awaiting
      applied = resolve({ run_id: run.id, decision: "approved", operator: "gui" })

      expect(applied.status).to eq(:applied)
      expect(agent_files.read("support", "TOOLS.md")).to include("Ask for the CEP first.")
      expect(agent_files.versions("support", "TOOLS.md").first["content"]).to eq(BODY)
      expect(applied.decision["by"]).to eq("gui")
    end

    # Rollback is not new machinery: the write versioned, so restore(…, 0) is it.
    it "rolls back through the history the write created" do
      run = awaiting
      resolve({ run_id: run.id, decision: "approved" })
      agent_files.restore("support", "TOOLS.md", 0)
      expect(agent_files.read("support", "TOOLS.md")).to eq(BODY)
    end

    it "records a rejection without touching a file" do
      run = awaiting
      rejected = resolve({ run_id: run.id, decision: "rejected", operator: "gui", note: "too wordy" })

      expect(rejected.status).to eq(:rejected)
      expect(rejected.decision["note"]).to eq("too wordy")
      expect(agent_files.read("support", "TOOLS.md")).to eq(BODY)
    end

    # THE case this command exists for. The gate scored a snapshot; a human edited
    # the same file in the Studio before approving. Applying anyway would silently
    # overwrite their work.
    it "refuses to apply when the file changed after the gate ran" do
      run = awaiting
      agent_files.write("support", "TOOLS.md", BODY.sub("quote freight.", "quote freight urgently."))

      expect { resolve({ run_id: run.id, decision: "approved" }) }
        .to raise_error(Insika::ValidationError, /files changed since this proposal was gated/)
      expect(agent_files.read("support", "TOOLS.md")).to include("urgently")
      expect(runs.find(run.id).status).to eq(:awaiting_approval) # still resolvable
    end

    it "refuses a decision it does not know, and a run nobody gated" do
      run = awaiting
      expect { resolve({ run_id: run.id, decision: "maybe" }) }
        .to raise_error(Insika::ValidationError, /invalid decision/)

      fresh = runs.complete(runs.create(agent_id: "support").id, findings: [{ "kind" => "x" }])
      expect { resolve({ run_id: fresh.id, decision: "approved" }) }
        .to raise_error(ArgumentError, /expected awaiting_approval/)
    end

    it "cannot be resolved twice" do
      run = awaiting
      resolve({ run_id: run.id, decision: "approved" })
      expect { resolve({ run_id: run.id, decision: "approved" }) }
        .to raise_error(ArgumentError, /expected awaiting_approval/)
    end

    it "reports which files changed on the applied event, and no content" do
      run = awaiting
      seen = []
      sub = events.subscribe
      Thread.new { sub.each { |e| seen << e } }
      resolve({ run_id: run.id, decision: "approved" })
      sleep 0.05
      sub.close

      applied = seen.find { |e| e.type == :refinement_applied }
      expect(applied.data[:files]).to eq(["TOOLS.md"])
      expect(JSON.generate(applied.data)).not_to include("Ask for the CEP")
    end
  end
end

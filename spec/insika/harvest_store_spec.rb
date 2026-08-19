# frozen_string_literal: true

require "spec_helper"

# C5 — the durable half of the harvest: one record per mining RUN, the
# per-candidate lifecycle, the APPEND-ONLY promotion log, the snapshots and
# the per-session mined markers. A dumb domain store: no policy (which
# candidate is worth gating is the gates'), no model, no skills — the
# SkillStore stays the skill's home.
RSpec.describe Insika::HarvestStore do
  subject(:store) { described_class.new(store: backend, session_store: session_source) }

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_source) { nil }

  def candidate_overrides
    { run_id: "run-1", agent: "store-support", name: "pix-recovery-followup",
      description: "d", body: "b", triggers: ["pix"], rationale: "r",
      origin: ["sess_1"], evidence_turns: [3, 5], proposer: "utility_model" }
  end

  def create_candidate(**overrides)
    store.create_candidate(**candidate_overrides.merge(overrides))
  end

  def gate(cand, eval_pass: true, conversion_pass: true)
    store.attach_gate(cand.id, eval_gate: { "passed" => eval_pass },
                               conversion_gate: { "passed" => conversion_pass },
                               criterion_sha: "sha256:abc")
  end

  def age_record!(key, field, iso)
    record = backend.get("harvest", key)
    record[field] = iso
    backend.set("harvest", key, record)
  end

  def find_key(prefix, suffix)
    backend.list("harvest", prefix).find { |k| k.end_with?(suffix) }
  end

  describe "runs" do
    it "create -> complete: completed with the candidate count and cost" do
      run = store.create_run(agent_id: "store-support", window: { last_sessions: 3 })
      expect(run.status).to eq("mining")
      expect(run.agent_id).to eq("store-support")
      expect(run.window).to eq("last_sessions" => 3)

      done = store.complete_run(run.id, candidates: 1, cost: { spent: 10 })
      expect(done.status).to eq("completed")
      expect(done.candidates).to eq(1)
      expect(done.cost).to eq("spent" => 10)
      expect(done.finished_at).to_not be_nil
      expect(store.find_run(run.id).status).to eq("completed")
    end

    it "complete with zero candidates -> :no_candidates (distinct from completed)" do
      run = store.create_run(agent_id: "a")
      expect(store.complete_run(run.id, candidates: 0).status).to eq("no_candidates")
    end

    it "fail_run records the error; a finished run cannot be re-completed (loud)" do
      run = store.create_run(agent_id: "a")
      failed = store.fail_run(run.id, error: "boom")
      expect(failed.status).to eq("failed")
      expect(failed.error).to eq("boom")
      expect { store.complete_run(run.id, candidates: 1) }
        .to raise_error(ArgumentError, /failed/)
    end

    it "runs_for is chronological-newest-first and capped; unknown run -> nil" do
      r1 = store.create_run(agent_id: "a")
      sleep 0.001
      r2 = store.create_run(agent_id: "a")
      store.create_run(agent_id: "other")
      expect(store.runs_for("a").map(&:id)).to eq([r2.id, r1.id])
      expect(store.runs_for("a", limit: 1).map(&:id)).to eq([r2.id])
      expect(store.find_run("nope")).to be_nil
    end
  end

  describe "candidates" do
    it "create round-trips; readable by id and by (agent, status); nil-tolerant" do
      cand = create_candidate
      expect(cand.status).to eq("pending")
      expect(cand.origin).to eq(["sess_1"])
      expect(cand.evidence_turns).to eq([3, 5])

      found = store.find_candidate(cand.id)
      expect(found.name).to eq("pix-recovery-followup")
      expect(found.agent).to eq("store-support")

      expect(store.candidates(agent_id: "store-support", status: "pending")).not_to be_nil
      expect(store.candidates(status: "promoted")).to eq([])
      expect(store.find_candidate("nope")).to be_nil
    end

    it "awaiting_approval is ONLY the human's inbox, most recent first, capped" do
      c2 = create_candidate
      gate(c2)
      store.mark_awaiting(c2.id)
      c1 = create_candidate
      store.mark_rejected(c1.id, operator: "studio", note: "no")

      expect(store.awaiting_approval.map(&:id)).to eq([c2.id])
    end

    it "open_pending? is the dedup by (agent, name): open until terminal" do
      expect(store.open_pending?(agent: "store-support", name: "pix-recovery-followup")).to be(false)
      cand = create_candidate
      expect(store.open_pending?(agent: "store-support", name: "pix-recovery-followup")).to be(true)
      expect(store.open_pending?(agent: "other", name: "pix-recovery-followup")).to be(false)

      gate(cand)
      store.mark_awaiting(cand.id)
      store.mark_promoted(cand.id, promotion_ref: "promo:1")
      expect(store.open_pending?(agent: "store-support", name: "pix-recovery-followup")).to be(false)
    end
  end

  describe "the candidate lifecycle (read-check-write transitions, the task_store idiom)" do
    it "attach_gate only from pending; both reports + the criterion sha land; a double gate is the loud bug" do
      cand = create_candidate
      attached = store.attach_gate(cand.id,
                                   eval_gate: { "passed" => true, "cases" => 7 },
                                   conversion_gate: { "passed" => false, "reason" => "no_fold" },
                                   criterion_sha: "sha256:x")
      expect(attached.status).to eq("gated")
      expect(attached.eval_gate).to eq("passed" => true, "cases" => 7)
      expect(attached.conversion_gate).to eq("passed" => false, "reason" => "no_fold")
      expect(attached.criterion_sha).to eq("sha256:x")

      expect { store.attach_gate(cand.id, eval_gate: {}, conversion_gate: {}, criterion_sha: "y") }
        .to raise_error(ArgumentError, /gated/)
    end

    it "mark_awaiting only from gated" do
      cand = create_candidate
      expect { store.mark_awaiting(cand.id) }.to raise_error(ArgumentError, /pending/)
      gate(cand)
      expect(store.mark_awaiting(cand.id).status).to eq("awaiting_approval")
    end

    it "mark_rejected is terminal from pending, gated AND awaiting (a human may always outvote)" do
      pending = create_candidate
      rejected = store.mark_rejected(pending.id, operator: "studio", note: "smells")
      expect(rejected.status).to eq("rejected")
      expect(rejected.decision).to include("by" => "studio", "note" => "smells")

      gated = create_candidate
      gate(gated)
      expect(store.mark_rejected(gated.id, operator: "gate", note: "regression").status).to eq("rejected")

      awaiting = create_candidate
      gate(awaiting)
      store.mark_awaiting(awaiting.id)
      expect { store.mark_awaiting(awaiting.id) }.to raise_error(ArgumentError, /awaiting/)
      expect(store.mark_rejected(awaiting.id, operator: "studio", note: "no").status).to eq("rejected")
    end

    it "mark_promoted only from awaiting_approval (record-after: the writes land first)" do
      cand = create_candidate
      expect { store.mark_promoted(cand.id, promotion_ref: "promo:1") }
        .to raise_error(ArgumentError, /pending/)

      gate(cand)
      store.mark_awaiting(cand.id)
      store.mark_promoted(cand.id, promotion_ref: "promo:1")
      found = store.find_candidate(cand.id)
      expect(found.status).to eq("promoted")
      expect(found.promotion_ref).to eq("promo:1")
    end

    it "a wrong source state raises and writes nothing" do
      cand = create_candidate
      expect { store.mark_promoted(cand.id, promotion_ref: "x") }.to raise_error(ArgumentError)
      expect(store.find_candidate(cand.id).status).to eq("pending")
    end
  end

  describe "the append-only promotion log (D8)" do
    it "appends the promotion row; no update/delete method exists" do
      row = store.append_promotion(
        id: "promo-1", agent: "store-support", skill: "pix-recovery-followup",
        origin: %w[sess_8f3c], eval_ref: "cand:c1",
        conversion_ref: "funnel:platform:store-support:2026-08-16",
        approver: "studio", snapshot_ref: "snap:s1", criterion_sha: "sha256:abc"
      )
      expect(row.id).to eq("promo-1")
      expect(row.agent).to eq("store-support")
      expect(row.skill).to eq("pix-recovery-followup")
      expect(row.origin).to eq(%w[sess_8f3c])
      expect(row.eval_ref).to eq("cand:c1")
      expect(row.conversion_ref).to eq("funnel:platform:store-support:2026-08-16")
      expect(row.approver).to eq("studio")
      expect(row.snapshot_ref).to eq("snap:s1")
      expect(row.criterion_sha).to eq("sha256:abc")
      expect(row.rolled_back_at).to be_nil
      expect(row.at).not_to be_nil

      expect(described_class.instance_methods(false)).to_not include(:update_promotion, :delete_promotion)
    end

    it "a second append of the same id raises loudly (append-only)" do
      store.append_promotion(id: "promo-1", agent: "a", skill: "s", approver: "studio")
      expect { store.append_promotion(id: "promo-1", agent: "a", skill: "s", approver: "studio") }
        .to raise_error(Insika::ValidationError, /promo-1/)
    end

    it "a rollback stamps rolled_back_at on the row — the log stays the single ledger (D9)" do
      store.append_promotion(id: "promo-2", agent: "a", skill: "s", approver: "studio")
      rolled = store.append_rollback(promotion_id: "promo-2", operator: "studio", reason: "audit")
      expect(rolled.rolled_back_at).not_to be_nil
      expect(store.promotions.find { |p| p.id == "promo-2" }.rolled_back_at).not_to be_nil
    end

    it "promotions(agent_id:, limit:) reads the ledger new-first" do
      store.append_promotion(id: "p1", agent: "a", skill: "s1", approver: "studio")
      store.append_promotion(id: "p2", agent: "b", skill: "s2", approver: "studio")
      store.append_promotion(id: "p3", agent: "a", skill: "s3", approver: "studio")
      expect(store.promotions(agent_id: "a").map(&:id)).to eq(%w[p3 p1])
      expect(store.promotions(agent_id: "a", limit: 1).map(&:id)).to eq(%w[p3])
      expect(store.promotions.map(&:id)).to eq(%w[p3 p2 p1])
    end
  end

  describe "snapshots" do
    it "round-trips the pre-promotion state (content nil + existed false = it never existed)" do
      snap = store.create_snapshot(agent: "store-support", skill: "pix-recovery-followup",
                                   content: nil, existed: false, enabled_for: %w[store-support])
      found = store.find_snapshot(snap.id)
      expect(found.content).to be_nil
      expect(found.existed).to be(false)
      expect(found.enabled_for).to eq(%w[store-support])
      expect(found.at).not_to be_nil
    end

    it "keeps the pre-promotion bytes for an overwritten skill" do
      snap = store.create_snapshot(agent: "a", skill: "s", content: "---\nname: s\n---\nold\n",
                                   existed: true, enabled_for: %w[a b])
      expect(store.find_snapshot(snap.id).content).to eq("---\nname: s\n---\nold\n")
      expect(store.find_snapshot("nope")).to be_nil
    end
  end

  describe "the per-session mined marker (D10's re-scan discipline)" do
    it "mined? is false until marked; mark_mined records the marker and returns it" do
      expect(store.mined?("acme:sess_1")).to be(false)
      marker = store.mark_mined("acme:sess_1", candidates: 2)
      expect(marker["session_ref"]).to eq("acme:sess_1")
      expect(marker["candidates"]).to eq(2)
      expect(marker["mined_at"]).not_to be_nil
      expect(store.mined?("acme:sess_1")).to be(true)
    end

    context "with a session source" do
      let(:session_source) do
        sessions = double("sessions")
        allow(sessions).to receive(:each_id).and_return(%w[a b c].each)
        allow(sessions).to receive(:find) do |id|
          double("session", id: id, updated_at: "2026-08-16T00:00:00Z")
        end
        sessions
      end

      it "unmined_sessions is the scan minus the marked set, and since: is the incremental boundary" do
        store.mark_mined("b")
        expect(store.unmined_sessions).to eq(%w[a c])
        expect(store.unmined_sessions(since: "2026-08-16T00:00:01Z")).to eq([])
      end
    end

    it "without a session source the scan is inert (nil never enumerates)" do
      expect(store.unmined_sessions).to eq([])
    end
  end

  describe "LGPD: purge + delete_older_than" do
    it "purge(tenant:) removes exactly the tenant's rows — candidates, log rows, markers; a neighbour survives" do
      mine = create_candidate(origin: %w[acme:sess_1])
      store.mark_mined("acme:sess_1")
      store.append_promotion(id: "px", agent: "store-support", skill: "s",
                             origin: %w[acme:sess_1], approver: "o")
      other = create_candidate(origin: %w[other:sess_9])
      store.append_promotion(id: "py", agent: "store-support", skill: "s2",
                             origin: %w[other:sess_9], approver: "o")

      expect(store.purge(tenant: "acme")).to eq(3)
      expect(store.find_candidate(mine.id)).to be_nil
      expect(store.promotions(agent_id: "store-support").map(&:id)).to eq(%w[py])
      expect(store.mined?("acme:sess_1")).to be(false)
      expect(store.find_candidate(other.id)).to_not be_nil
      expect(store.mined?("other:sess_9")).to be(false)
    end

    it "delete_older_than sweeps pending AND terminal candidates, log rows, snapshots and runs past the cutoff — fresh ones survive; markers never die (the claim)" do
      old = (Time.now.utc - 100 * 86_400).iso8601

      old_cand = create_candidate
      age_record!("cand:#{old_cand.id}", "created_at", old)
      age_record!("cand:#{old_cand.id}", "updated_at", old)
      old_promo = store.append_promotion(id: "op", agent: "a", skill: "s", approver: "o")
      promo_key = find_key("promo:", ":#{old_promo.id}")
      age_record!(promo_key, "at", old)
      snap = store.create_snapshot(agent: "a", skill: "s", content: "x", existed: true, enabled_for: ["a"])
      age_record!("snap:#{snap.id}", "at", old)
      old_run = store.create_run(agent_id: "a")
      run_key = find_key("run:a:", ":#{old_run.id}")
      age_record!(run_key, "started_at", old)

      fresh_cand = create_candidate
      store.append_promotion(id: "fp", agent: "a", skill: "s2", approver: "o")
      fresh_snap = store.create_snapshot(agent: "a", skill: "s2", content: "y", existed: true, enabled_for: ["a"])
      store.mark_mined("kept:sess_1")

      removed = store.delete_older_than(Time.parse(old) + 1)
      expect(store.find_candidate(old_cand.id)).to be_nil
      expect(store.find_candidate(fresh_cand.id)).to_not be_nil
      expect(store.find_snapshot(fresh_snap.id)).to_not be_nil
      expect(store.promotions.map(&:id)).to eq(%w[fp])
      expect(store.mined?("kept:sess_1")).to be(true)
      expect(removed).to be >= 4
    end
  end
end
# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # RFC-0035 C5: the durable half of the harvest. One record per mining RUN
  # (window, candidates, cost), the per-candidate lifecycle (the unit a human
  # acts on — D8), the APPEND-ONLY promotion log, the pre-promotion snapshots,
  # and the per-session mined markers (D10's re-scan discipline). A dumb
  # domain store: no policy (which candidate is worth gating is the gates'),
  # no model, no skills — the SkillStore stays the skill's home.
  #
  # Key shapes (string keys, Store-contract JSON):
  #   "harvest"   "run:<agent>:<started_at>:<id>"     -> the mining run
  #   "harvest"   "cand:<id>"                         -> one candidate lifecycle
  #   "harvest"   "promo:<agent>:<at>:<id>"         -> APPEND ONLY (D8)
  #   "harvest"   "snap:<id>"                       -> the pre-promotion state
  #   "harvest"   "session:<session_ref>"           -> the D10 marker
  #
  # The agent id must not contain ":" (the run-key split — the RefinementStore
  # rule). The `body` is the only content the store holds: behavior
  # instructions, the same trust level as SkillStore content (D11).
  class HarvestStore
    SCOPE = "harvest"

    # Run statuses: mining -> completed | no_candidates | failed. The run does
    # NOT carry awaiting_approval: several candidates of one run can be at
    # different gates (D8) — the human answers CANDIDATES, the run only frames.
    RUN_STATUSES = %w[mining completed no_candidates failed].freeze
    # Candidate statuses (the lifecycle a human acts on):
    #   pending -> gated -> awaiting_approval -> promoted | rejected
    #          (gated FAIL -> rejected with the report; the latch)
    CANDIDATE_STATUSES = %w[pending gated awaiting_approval promoted rejected].freeze
    # A candidate is OPEN (dedup-suppressing) until terminal.
    OPEN_STATUSES = %w[pending gated awaiting_approval].freeze

    Candidate = Data.define(:id, :run_id, :agent, :name, :description, :body,
                            :triggers, :rationale, :origin, :evidence_turns,
                            :proposer, :status, :rejected, :eval_gate,
                            :conversion_gate, :criterion_sha, :decision,
                            :promotion_ref, :created_at, :updated_at)
    Promotion = Data.define(:id, :agent, :skill, :origin, :eval_ref,
                            :conversion_ref, :approver, :snapshot_ref,
                            :criterion_sha, :rolled_back_at, :at)
    Snapshot = Data.define(:id, :agent, :skill, :content, :existed, :enabled_for, :at)
    Run = Data.define(:id, :agent_id, :status, :window, :candidates, :rejected,
                      :budget, :cost, :started_at, :finished_at, :error)

    # session_store: optional — the session source for `unmined_sessions`
    # (D10). nil = the scan is inert (the engine may enumerate sessions
    # itself; the store never invents a session space).
    def initialize(store:, session_store: nil)
      @store = store
      @sessions = session_store
    end

    # ---- runs -----------------------------------------------------------------

    # Opens a run (:mining). `window` is the miner's window as data
    # ({ "last_sessions" => N } | { "since" => iso8601 } | { "session_ids" => [...] }).
    # `budget` is the pack's harvest.miner.budget (the cap the gates read —
    # the refinement budget discipline). -> Run.
    def create_run(agent_id:, window: {}, budget: nil, id: SecureRandom.uuid)
      agent = agent_id.to_s
      raise Insika::ValidationError, "agent_id is required" if agent.empty?
      raise Insika::ValidationError, "agent_id must not contain ':'" if agent.include?(":")

      started = timestamp
      record = {
        "id" => id.to_s, "agent_id" => agent, "status" => "mining",
        "window" => Coercion.deep_stringify(window || {}),
        "candidates" => 0, "rejected" => {}, "budget" => Coercion.deep_stringify(budget),
        "cost" => nil,
        "started_at" => started, "finished_at" => nil, "error" => nil
      }
      @store.set(SCOPE, "run:#{agent}:#{started}:#{id}", record)
      to_run(record)
    end

    # Closes a run with its candidate count. Zero candidates -> :no_candidates
    # (a distinct outcome from :completed — "we looked and it was clean").
    # `rejected` is the { reason/rule => count } map the filters counted (D4:
    # "every rejected-by-list candidate is logged with the matching rule").
    # -> Run. ArgumentError when the run is already terminal.
    def complete_run(id, candidates:, cost: nil, rejected: nil)
      update_run(id) do |record|
        guard_run_state!(record, "mining")
        record["candidates"] = Integer(candidates)
        record["rejected"] = rejected ? Coercion.deep_stringify(rejected) : {}
        record["cost"] = Coercion.deep_stringify(cost) if cost
        record["status"] = Integer(candidates).positive? ? "completed" : "no_candidates"
        record["finished_at"] = timestamp
      end
    end

    # Closes a run as :failed, recording the error. -> Run.
    def fail_run(id, error:)
      update_run(id) do |record|
        guard_run_state!(record, "mining")
        record["status"] = "failed"
        record["error"] = error.to_s
        record["finished_at"] = timestamp
      end
    end

    def find_run(id)
      key = run_key(id)
      key && to_run(@store.get(SCOPE, key))
    end

    # -> [Run] for one agent, MOST RECENT FIRST, capped.
    def runs_for(agent_id, limit: 20)
      keys = @store.list(SCOPE, "run:#{agent_id}:").reverse
      keys = keys.first(limit) if limit
      keys.filter_map { |k| to_run(@store.get(SCOPE, k)) }
    end

    # ---- candidates -----------------------------------------------------------

    # The engine stamps agent/origin/proposer — never the model (D3).
    def create_candidate(run_id:, agent:, name:, description:, body:,
                         triggers: [], rationale:, origin:, evidence_turns: [],
                         proposer:, id: SecureRandom.uuid)
      now = timestamp
      record = {
        "id" => id.to_s, "run_id" => run_id.to_s, "agent" => agent.to_s,
        "name" => name.to_s, "description" => description.to_s, "body" => body.to_s,
        "triggers" => Array(triggers).map(&:to_s), "rationale" => rationale.to_s,
        "origin" => Array(origin).map(&:to_s),
        "evidence_turns" => Array(evidence_turns).map(&:to_i),
        "proposer" => proposer.to_s, "status" => "pending",
        "rejected" => [], "eval_gate" => nil, "conversion_gate" => nil,
        "criterion_sha" => nil, "decision" => nil, "promotion_ref" => nil,
        "created_at" => now, "updated_at" => now
      }
      @store.set(SCOPE, "cand:#{id}", record)
      to_candidate(record)
    end

    def find_candidate(id)
      to_candidate(@store.get(SCOPE, "cand:#{id}"))
    end

    # -> [Candidate] filtered by agent/status, most recent first.
    def candidates(agent_id: nil, status: nil)
      scan_candidates.select do |c|
        (agent_id.nil? || c.agent == agent_id.to_s) &&
          (status.nil? || c.status == status.to_s)
      end
    end

    # -> [Candidate] EVERY candidate parked on a human, most recent first.
    def awaiting_approval(limit: 50)
      list = candidates(status: "awaiting_approval").sort_by { |c| c.updated_at.to_s }.reverse
      list.first(limit)
    end

    # Dedup: an OPEN (non-terminal) candidate with the same (agent, name)
    # suppresses a re-proposal. -> bool.
    def open_pending?(agent:, name:)
      @store.list(SCOPE, "cand:").any? do |k|
        record = @store.get(SCOPE, k)
        next false unless record
        next false unless record["agent"] == agent.to_s && record["name"] == name.to_s

        OPEN_STATUSES.include?(record["status"].to_s)
      end
    end

    # Transitions (read-check-write on #transaction; ArgumentError on a wrong
    # source state — the task_store idiom).

    # Appends a { rule, reason } rejection entry (the negative-list / gate
    # evidence lines). Accumulates; only on a non-terminal candidate.
    def attach_rejected(candidate_id, rules:, reason:)
      update_candidate(candidate_id) do |record|
        guard_candidate_non_terminal!(record)
        list = record["rejected"] || []
        record["rejected"] = list + Array(rules).map { |r| { "rule" => r.to_s, "reason" => reason.to_s } }
      end
    end

    # Records both gate reports + the boot-loaded criterion sha; pending ->
    # gated.
    def attach_gate(candidate_id, eval_gate:, conversion_gate:, criterion_sha:)
      update_candidate(candidate_id) do |record|
        guard_candidate_state!(record, "pending")
        record["eval_gate"] = Coercion.deep_stringify(eval_gate)
        record["conversion_gate"] = Coercion.deep_stringify(conversion_gate)
        record["criterion_sha"] = criterion_sha.to_s
        record["status"] = "gated"
        record["updated_at"] = timestamp
      end
    end

    # gated -> awaiting_approval. The refusal parks: a conversion REFUSAL
    # keeps the candidate AT gated (the page shows the ruler's hole).
    def mark_awaiting(candidate_id)
      update_candidate(candidate_id) do |record|
        guard_candidate_state!(record, "gated")
        record["status"] = "awaiting_approval"
        record["updated_at"] = timestamp
      end
    end

    # -> rejected (terminal) from pending | gated | awaiting_approval — a
    # human may always outvote the miner. The decision records by/at/note.
    def mark_rejected(candidate_id, operator:, note: nil)
      update_candidate(candidate_id) do |record|
        guard_candidate_non_terminal!(record)
        record["status"] = "rejected"
        record["decision"] = { "by" => (Coercion.presence(operator) || "operator").to_s,
                               "at" => timestamp, "note" => Coercion.presence(note) }.compact
        record["updated_at"] = timestamp
      end
    end

    # awaiting_approval -> promoted. Recorded ONLY after the writes land (the
    # record-after rule).
    def mark_promoted(candidate_id, promotion_ref:)
      update_candidate(candidate_id) do |record|
        guard_candidate_state!(record, "awaiting_approval")
        record["status"] = "promoted"
        record["promotion_ref"] = promotion_ref.to_s
        record["updated_at"] = timestamp
      end
    end

    # D8-bis: the conversion ruler is re-read AT APPROVE TIME and may have
    # moved below the threshold since gating. The promote path re-checks; a
    # dip parks the candidate BACK at gated with the FRESH report — the
    # operator re-decides, and a skill does not land into a ruler that has
    # moved the wrong way. awaiting_approval -> gated.
    def recheck_conversion(candidate_id, conversion_gate:)
      update_candidate(candidate_id) do |record|
        guard_candidate_state!(record, "awaiting_approval")
        record["conversion_gate"] = Coercion.deep_stringify(conversion_gate)
        record["status"] = "gated"
        record["updated_at"] = timestamp
      end
    end

    # ---- the append-only promotion log + snapshots ----------------------------

    # Appends the RFC row — NO update, NO delete, no re-key. A second row with
    # the same id is refused loudly.
    def append_promotion(id:, agent:, skill:, origin: [], eval_ref: nil,
                         conversion_ref: nil, approver:, snapshot_ref: nil,
                         criterion_sha: nil, at: nil)
      id = id.to_s
      agent = agent.to_s
      raise Insika::ValidationError, "promotion id is required" if id.empty?
      raise Insika::ValidationError, "promotion already recorded: #{id}" if find_promotion_key(id)

      now = at || timestamp
      record = {
        "id" => id, "agent" => agent, "skill" => skill.to_s,
        "origin" => Array(origin).map(&:to_s), "eval_ref" => eval_ref.to_s,
        "conversion_ref" => conversion_ref.to_s, "approver" => (Coercion.presence(approver) || "operator").to_s,
        "snapshot_ref" => snapshot_ref.to_s, "criterion_sha" => criterion_sha.to_s,
        "rolled_back_at" => nil, "at" => now
      }
      @store.set(SCOPE, "promo:#{agent}:#{now}:#{id}", record)
      to_promotion(record)
    end

    # Stamps rolled_back_at on the row — the log stays the single ledger (D9).
    # -> Promotion.
    def append_rollback(promotion_id:, operator: nil, reason: nil)
      key = find_promotion_key(promotion_id.to_s)
      raise Insika::NotFoundError, "promotion not found: #{promotion_id}" if key.nil?

      record = @store.get(SCOPE, key)
      record["rolled_back_at"] = timestamp
      @store.set(SCOPE, key, record)
      to_promotion(record)
    end

    # -> [Promotion] new-first, optionally per agent, capped.
    def promotions(agent_id: nil, limit: 100)
      keys = @store.list(SCOPE, agent_id ? "promo:#{agent_id}:" : "promo:")
      rows = keys.filter_map { |k| to_promotion(@store.get(SCOPE, k)) }
      rows.sort_by { |p| p.at.to_s }.reverse.first(limit)
    end

    # The pre-promotion state (D8 — snapshot FIRST, then the writes).
    def create_snapshot(agent:, skill:, content:, existed:, enabled_for:)
      id = SecureRandom.uuid
      record = { "id" => id, "agent" => agent.to_s, "skill" => skill.to_s,
                 "content" => content, "existed" => !!existed,
                 "enabled_for" => Array(enabled_for).map(&:to_s),
                 "at" => timestamp }
      @store.set(SCOPE, "snap:#{id}", record)
      to_snapshot(record)
    end

    def find_snapshot(id)
      to_snapshot(@store.get(SCOPE, "snap:#{id}"))
    end

    # ---- the per-session marker (D10 - the re-scan discipline) ----------------

    def mark_mined(session_ref, candidates: 0)
      ref = session_ref.to_s
      return {} if ref.empty?

      record = { "session_ref" => ref, "mined_at" => timestamp,
                 "candidates" => Integer(candidates) }
      @store.set(SCOPE, "session:#{ref}", record)
      record
    end

    def mined?(session_ref)
      !@store.get(SCOPE, "session:#{session_ref.to_s}").nil?
    end

    # The engine's scan space: every session the source knows MINUS the marked
    # set, optionally bounded by `since` (sessions updated at/after it — the
    # incremental boundary). Nil source = inert (parity — the caller that owns
    # a SessionStore enumerates itself).
    # -> [String]
    def unmined_sessions(since: nil)
      return [] unless @sessions

      @sessions.each_id.filter_map do |id|
        next if mined?(id)

        if since
          session = @sessions.respond_to?(:find) ? @sessions.find(id) : nil
          next unless session
          next unless Time.parse(session.updated_at.to_s).utc >= Time.parse(since.to_s).utc
        end
        id.to_s
      rescue ArgumentError
        next
      end.to_a
    end

    # ---- LGPD / retention (C13) -----------------------------------------------

    # The tenant is the store's (candidates reference sessions; sessions carry
    # the tenant prefix) — a prefix scan over the scope keys. Removes the
    # tenant's candidates, promotion rows, their snapshots and the session
    # markers. -> count removed.
    def purge(tenant:)
      prefix = "#{tenant_id(tenant)}:"
      removed = 0

      promo_refs = []
      @store.list(SCOPE, "promo:").each do |k|
        record = @store.get(SCOPE, k)
        next unless record && Array(record["origin"]).any? { |o| o.to_s.start_with?(prefix) }

        @store.delete(SCOPE, k)
        promo_refs << record["snapshot_ref"].to_s
        removed += 1
      end

      @store.list(SCOPE, "cand:").each do |k|
        record = @store.get(SCOPE, k)
        next unless record && Array(record["origin"]).any? { |o| o.to_s.start_with?(prefix) }

        @store.delete(SCOPE, k)
        removed += 1
      end

      promo_refs.each do |ref|
        next if ref.empty?

        snap_key = "snap:#{ref}"
        existing = @store.get(SCOPE, snap_key)
        next unless existing

        @store.delete(SCOPE, snap_key)
        removed += 1
      end

      @store.list(SCOPE, "session:#{prefix}").each do |k|
        @store.delete(SCOPE, k)
        removed += 1
      end

      removed
    end

    # Candidates (pending AND terminal), log rows, snapshots and runs past the
    # cutoff. They are re-derivable (D2) — pruning is never data loss. The
    # session MARKERS are never pruned (the marker is the claim).
    # -> count removed.
    def delete_older_than(time)
      cutoff = Time.parse(time.to_s).utc
      removed = 0

      [["cand:", "created_at"], ["snap:", "at"], ["run:", "started_at"]].each do |prefix, field|
        @store.list(SCOPE, prefix).each do |k|
          record = @store.get(SCOPE, k)
          next unless record && record[field]

          begin
            next unless Time.parse(record[field].to_s).utc < cutoff
          rescue ArgumentError
            next
          end

          @store.delete(SCOPE, k)
          removed += 1
        end
      end

      @store.list(SCOPE, "promo:").each do |k|
        record = @store.get(SCOPE, k)
        next unless record && record["at"]

        begin
          next unless Time.parse(record["at"].to_s).utc < cutoff
        rescue ArgumentError
          next
        end

        @store.delete(SCOPE, k)
        removed += 1
      end

      removed
    end

    private

    def tenant_id(tenant)
      t = tenant.to_s
      t.empty? ? "platform" : t
    end

    # Fractional seconds so the run/promotion keys ("...:<started_at>:<id>")
# order CHRONOLOGICALLY under the store's lexicographic contract even for two
# writes in the same second (the "runs_for is newest-first" guarantee).
    def timestamp = Time.now.utc.iso8601(6)

    def run_key(id)
      suffix = ":#{id}"
      @store.list(SCOPE, "run:").find { |k| k.end_with?(suffix) }
    end

    def find_promotion_key(id)
      suffix = ":#{id}"
      @store.list(SCOPE, "promo:").find { |k| k.end_with?(suffix) }
    end

    def update_run(id)
      key = run_key(id.to_s)
      raise Insika::NotFoundError, "harvest run not found: #{id}" if key.nil?

      record = @store.get(SCOPE, key)
      if record.nil?
        raise Insika::NotFoundError, "harvest run not found: #{id}"
      end

      yield record
      @store.set(SCOPE, key, record)
      to_run(record)
    end

    def guard_run_state!(record, expected)
      return if record["status"] == expected

      raise ArgumentError, "run #{record['id']} is #{record['status']}, expected #{expected}"
    end

    def update_candidate(candidate_id)
      key = "cand:#{candidate_id}"
      record = @store.get(SCOPE, key)
      raise Insika::NotFoundError, "harvest candidate not found: #{candidate_id}" if record.nil?

      yield record
      record["updated_at"] = timestamp
      @store.set(SCOPE, key, record)
      to_candidate(record)
    end

    def guard_candidate_state!(record, expected)
      return if record["status"] == expected

      raise ArgumentError, "candidate #{record['id']} is #{record['status']}, expected #{expected}"
    end

    def guard_candidate_non_terminal!(record)
      return if OPEN_STATUSES.include?(record["status"].to_s)

      raise ArgumentError, "candidate #{record['id']} is already #{record['status']}"
    end

    def scan_candidates
      @store.list(SCOPE, "cand:").filter_map { |k| to_candidate(@store.get(SCOPE, k)) }
    end

    def to_run(record)
      return nil if record.nil?

      Run.new(
        id: record["id"], agent_id: record["agent_id"],
        status: record["status"].to_s, window: record["window"] || {},
        candidates: record["candidates"] || 0, rejected: record["rejected"] || {},
        budget: record["budget"], cost: record["cost"],
        started_at: record["started_at"], finished_at: record["finished_at"],
        error: record["error"]
      )
    end

    def to_candidate(record)
      return nil if record.nil?

      Candidate.new(
        id: record["id"], run_id: record["run_id"], agent: record["agent"],
        name: record["name"], description: record["description"], body: record["body"],
        triggers: Array(record["triggers"]), rationale: record["rationale"],
        origin: Array(record["origin"]), evidence_turns: Array(record["evidence_turns"]),
        proposer: record["proposer"], status: record["status"].to_s,
        rejected: record["rejected"] || [], eval_gate: record["eval_gate"],
        conversion_gate: record["conversion_gate"], criterion_sha: record["criterion_sha"],
        decision: record["decision"], promotion_ref: record["promotion_ref"],
        created_at: record["created_at"], updated_at: record["updated_at"]
      )
    end

    def to_promotion(record)
      return nil if record.nil?

      Promotion.new(
        id: record["id"], agent: record["agent"], skill: record["skill"],
        origin: Array(record["origin"]), eval_ref: record["eval_ref"],
        conversion_ref: record["conversion_ref"], approver: record["approver"],
        snapshot_ref: record["snapshot_ref"], criterion_sha: record["criterion_sha"],
        rolled_back_at: record["rolled_back_at"], at: record["at"]
      )
    end

    def to_snapshot(record)
      return nil if record.nil?

      Snapshot.new(
        id: record["id"], agent: record["agent"], skill: record["skill"],
        content: record["content"], existed: record["existed"] == true,
        enabled_for: Array(record["enabled_for"]), at: record["at"]
      )
    end
  end
end
# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # the proposals and the two persisted mechanisms the gates
  # on — the **latched dedup ledger** (D3: the rows themselves ARE the ledger —
  # a dismissed/rejected tuple is never proposed again, and an unanswered
  # proposal is not piled on) and the **per-session distilled marker** (D2:
  # written only after a pass completes, so a crash mid-pass leaves the marker
  # unwritten and the next pass re-scans). A dumb domain store — it holds no
  # policy (which tuple is a fact is the distiller's job), no memory facts and
  # no model. The scope string (the memory cell) is built by the callers from
  # the   `MemoryStore::parse_cell` shape; the store keys by
  # `(tenant, customer)` explicitly.
  #
  # Statuses: pending -> approved | rejected | dismissed | stale.
  # `stale` is the CAS-lost re-present (E3): the proposal carries the fact's
  # CURRENT value (`current_value`) next to the proposed one, never a silent
  # overwrite.
  class ProposalStore
    SCOPE = "proposals"
    STATUSES = %w[pending approved rejected dismissed stale].freeze
    TERMINAL = %w[approved rejected dismissed].freeze
    PROPOSAL_PREFIX = "p:"
    MARKER_PREFIX = "s:"

    Proposal = Data.define(:id, :tenant, :customer, :scope, :session_ref, :key,
                           :value, :confidence, :status, :evidence,
                           :expected_revision, :expected_existed, :current_value,
                           :operator, :note, :created_at, :updated_at)

    def initialize(store:)
      @store = store
    end

    # -> Proposal (status :pending). The caller (RunDistillation) already ran
    # the dedup checks; the store writes. `evidence` = message indexes; the
    # revision baseline (D5) travels with the record.
    #
    # The tenant is stored VERBATIM — nil in a single-tenant deployment, so
    # the scope is the bare `customer` cell and the approval reads/writes the
    # SAME cell the Memory provider injects (memory_store.rb's
    # blank-tenant + customer -> "memory:<customer>" rule). Coercing a blank
    # tenant to a sentinel here would orphan every approved fact in a
    # phantom "memory:platform:<customer>" cell.
    def create(tenant:, customer:, session_ref:, key:, value:, confidence: nil,
               evidence: [], expected_revision: nil, expected_existed: false,
               id: SecureRandom.uuid, now: Time.now.utc)
      tenant = tenant_key(tenant)
      stamp = now.iso8601(6)
      record = { "id" => id.to_s, "status" => "pending",
                 "tenant" => tenant, "customer" => customer.to_s,
                 "scope" => [tenant, customer.to_s].compact.join(":"),
                 "session_ref" => session_ref.to_s, "key" => key.to_s,
                 "value" => value.to_s, "confidence" => confidence,
                 "evidence" => Array(evidence).map(&:to_i),
                 "expected_revision" => expected_revision,
                 "expected_existed" => !!expected_existed,
                 "current_value" => nil, "operator" => nil, "note" => nil,
                 "created_at" => stamp, "updated_at" => stamp }
      @store.set(SCOPE, PROPOSAL_PREFIX + id.to_s, record)
      to_proposal(record)
    end

    def find(id)
      record = @store.get(SCOPE, PROPOSAL_PREFIX + id.to_s)
      record && to_proposal(record)
    end

    # The wiki's lists. `pending` = pending, oldest first (the operator works
    # the oldest proposal first — evidence ages).
    def pending(limit: 100)
      scan.select { |p| p.status == "pending" }
          .sort_by { |p| [p.created_at.to_s, p.id] }
          .first(limit)
    end

    def stale(limit: 50)
      scan.select { |p| p.status == "stale" }
          .sort_by { |p| p.updated_at.to_s }
          .first(limit)
    end

    # The wiki's Recent list: every terminal status (approved/rejected/
    # dismissed), most recent first — the operator's audit trail.
    def resolved(limit: 20)
      scan.select { |p| TERMINAL.include?(p.status) }
          .sort_by { |p| p.updated_at.to_s }
          .reverse
          .first(limit)
    end

    # ---- the latched dedup (D3) ----
    # true when a dismissed/rejected row exists for the exact tuple — the
    # latch. Persisted rows ARE the ledger. A *different* value for the same
    # `name` is a different tuple.
    def decided?(tenant:, customer:, key:, value:)
      scan.any? do |p|
        tenant_key(p.tenant) == tenant_key(tenant) && p.customer == customer.to_s &&
          p.key == key.to_s && p.value == value.to_s &&
          %w[dismissed rejected].include?(p.status)
      end
    end

    # true when a pending row exists for (scope, key) — no piling.
    def open_pending?(tenant:, customer:, key:)
      scan.any? do |p|
        tenant_key(p.tenant) == tenant_key(tenant) && p.customer == customer.to_s &&
          p.key == key.to_s && p.status == "pending"
      end
    end

    # ---- transitions, each read-check-write on @store.transaction ----
    # pending -> terminal. ArgumentError for a wrong source state (the
    # task_store.rb state-machine idiom).
    def approve(id:, operator: nil, note: nil, now: Time.now.utc)
      transition(id, "approved", operator: operator, note: note, now: now)
    end

    def reject(id:, operator: nil, note: nil, now: Time.now.utc)
      transition(id, "rejected", operator: operator, note: note, now: now)
    end

    def dismiss(id:, operator: nil, note: nil, now: Time.now.utc)
      transition(id, "dismissed", operator: operator, note: note, now: now)
    end

    # pending -> stale, CAS lost; `current_value` = the fact as it stands (the
    # re-present's second value, E3).
    def mark_stale(id:, current_value:, operator: nil, now: Time.now.utc)
      transition(id, "stale", operator: operator, current_value: current_value, now: now)
    end

    # ---- the per-session marker (D2) ----
    # Written ONLY after a pass completes (RunDistillation). -> the marker hash.
    def mark_distilled(session_ref, agent:, proposals:, dropped:, deduped: 0, cost: nil, now: Time.now.utc)
      marker = { "session_ref" => session_ref.to_s, "agent" => agent.to_s,
                 "distilled_at" => now.iso8601, "proposals" => proposals.to_i,
                 "dropped" => dropped, "deduped" => deduped.to_i,
                 "cost" => cost }
      @store.set(SCOPE, MARKER_PREFIX + session_ref.to_s, marker)
      marker
    end

    def distilled?(session_ref)
      !@store.get(SCOPE, MARKER_PREFIX + session_ref.to_s).nil?
    end

    def distilled_sessions(agent_id = nil)
      keys = agent_id ? marker_keys.select { |k| marker_agent(k) == agent_id.to_s } : marker_keys
      keys.map { |k| k.delete_prefix(MARKER_PREFIX) }
    end

    # ---- LGPD / retention (C8) ----

    # One customer's proposals, EVERY status. -> count removed.
    def purge_customer(tenant:, customer:)
      removed = 0
      @store.transaction do
        proposal_keys.each do |k|
          record = @store.get(SCOPE, k)
          next unless record && record["tenant"] == tenant_key(tenant)
          next unless record["customer"] == customer.to_s

          @store.delete(SCOPE, k)
          removed += 1
        end
      end
      removed
    end

    # A tenant's proposals. -> count removed.
    def purge(tenant:)
      removed = 0
      @store.transaction do
        proposal_keys.each do |k|
          record = @store.get(SCOPE, k)
          next unless record && record["tenant"] == tenant_key(tenant)

          @store.delete(SCOPE, k)
          removed += 1
        end
      end
      removed
    end

    # Age-based prune (the retention sweep). TERMINAL rows age by their
    # updated_at; a PENDING row is a zombie past the cutoff (its transcript is
    # dead). Session MARKERS die WITH their proposals — a marker past the
    # cutoff is evidence about a dead transcript (the session aged out under
    # the same retention window), and keeping it would lock an unreviewed
    # proposal out of re-distillation forever. -> count removed.
    def delete_older_than(time)
      cutoff = time.utc.iso8601
      removed = 0
      @store.transaction do
        proposal_keys.each do |k|
          record = @store.get(SCOPE, k)
          next unless record

          terminal = TERMINAL.include?(record["status"])
          stamp = terminal ? record["updated_at"] : record["created_at"]
          next unless stamp && stamp.to_s < cutoff

          @store.delete(SCOPE, k)
          removed += 1
        end
        marker_keys.each do |k|
          marker = @store.get(SCOPE, k)
          next unless marker && marker["distilled_at"].to_s < cutoff

          @store.delete(SCOPE, k)
          removed += 1
        end
      end
      removed
    end

    private

    def transition(id, to, operator: nil, note: nil, current_value: nil, now: Time.now.utc)
      @store.transaction do
        key = PROPOSAL_PREFIX + id.to_s
        record = @store.get(SCOPE, key)
        raise Insika::NotFoundError, "proposal not found: #{id}" if record.nil?

        unless record["status"] == "pending"
          raise ArgumentError,
                "proposal #{id}: cannot resolve a #{record['status']} proposal — " \
                "it resolves once, from pending"
        end

        record["status"] = to
        record["operator"] = operator.to_s unless operator.nil?
        record["note"] = note.to_s unless note.nil?
        record["current_value"] = current_value unless current_value.nil?
        record["updated_at"] = now.iso8601(6)
        @store.set(SCOPE, key, record)
        to_proposal(record)
      end
    end

    def scan
      proposal_keys.filter_map do |k|
        record = @store.get(SCOPE, k)
        record && to_proposal(record)
      end
    end

    def proposal_keys = @store.list(SCOPE, PROPOSAL_PREFIX)
    def marker_keys = @store.list(SCOPE, MARKER_PREFIX)

    # nil stays nil (single-tenant); a present tenant is a String. The
    # comparisons below use tenant_key on BOTH sides so nil == nil holds.
    def tenant_key(tenant) = tenant.nil? ? nil : tenant.to_s

    def to_proposal(rec)
      Proposal.new(id: rec["id"], tenant: rec["tenant"], customer: rec["customer"],
                   scope: rec["scope"], session_ref: rec["session_ref"],
                   key: rec["key"], value: rec["value"], confidence: rec["confidence"],
                   status: rec["status"], evidence: rec["evidence"] || [],
                   expected_revision: rec["expected_revision"],
                   expected_existed: rec["expected_existed"] == true,
                   current_value: rec["current_value"], operator: rec["operator"],
                   note: rec["note"], created_at: rec["created_at"],
                   updated_at: rec["updated_at"])
    end
  end
end

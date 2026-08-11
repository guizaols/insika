# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # REFINEMENT DOMAIN store. One record per refinement RUN:
  # the window that was read, the ranked findings the EvidenceCollector produced,
  # and the run's outcome. RUNTIME data (it is derived from sessions/tasks/traces),
  # so it takes the raw `store:` like SessionStore/TaskStore — not the ConfigStore.
  #
  # The key embeds the agent and the start timestamp:
  #   "run:<agent_id>:<started_at>:<id>"
  # so `list(SCOPE, "run:<agent>:")` comes back CHRONOLOGICAL for that agent (the
  # Store contract orders lexicographically) and `latest_for` is its last element.
  # An agent id containing ":" would break that split, so it is rejected on write.
  #
  # wrote no edits anywhere — a Run was a REPORT and every non-collecting
  # status was terminal. adds the rest of the lifecycle on
  # the SAME record, additively: a gated candidate and the operator's decision.
  #
  #   collecting ─▶ completed ─▶ gating ─▶ awaiting_approval ─▶ applied
  #             ╰─▶ no_findings          ╰─▶ rejected  (the gate failed it,
  #             ╰─▶ failed                    or the operator did)
  #
  # **The approval lives here, not in `PendingActionStore`** — a deliberate deviation
  # from That store is coupled to a suspended TURN: `ApproveAction` resolves
  # the record and then calls `executor.approve(task_id)` to wake a fiber. A
  # refinement proposal has no turn and no fiber, so reusing it would mean inventing
  # a task id, a fake `tool` name, and a wake-up that must never do anything — and
  # the operator's approvals inbox would fill with rows that are not tool calls. The
  # property actually wanted is durability across a `kill -9`, and this store
  # has had it since.
  class RefinementStore
    include Coercion

    SCOPE = "refinements"
    KEY_PREFIX = "run:"

    STATUSES = %i[collecting completed gating awaiting_approval applied rejected
                  no_findings failed].freeze

    # OPEN means "this run will change without anyone asking": work is in flight
    # (`collecting`, `gating`) or a human owes it an answer (`awaiting_approval`).
    # Everything else is terminal — INCLUDING `completed`, which already
    # treated that way and which stays true: a report is finished, and gating one is
    # a new deliberate action, not a continuation. (Widening `terminal?` here is what
    # the Studio's "latest report" lookup reads, so getting it wrong hides the report.)
    OPEN = %i[collecting gating awaiting_approval].freeze

    # `candidate`/`gate` are the WINNER — the one proposal a human is asked about, and
    # the only thing `ResolveRefinement` ever applies. `candidates` is the whole panel
    # every candidate that was built, who wrote it, and how
    # it scored, including the ones that lost and the ones the budget never gated. A
    # phase-C run recorded one candidate and no panel; it still reads back correctly,
    # because a panel of one is the same shape.
    Run = Data.define(:id, :agent_id, :status, :window, :findings, :excluded,
                      :started_at, :finished_at, :error,
                      :candidate, :candidates, :gate, :cost, :decision) do
      def terminal? = !OPEN.include?(status)
      def findings_count = findings.size

      # Is there a gated proposal waiting for a human? The one question the Studio
      # and the apply command both ask.
      def awaiting_approval? = status == :awaiting_approval
      def gate_passed? = gate.is_a?(Hash) && gate["passed"] == true
      def edits = (candidate || {})["edits"] || []
      def panel = Array(candidates)
    end

    def initialize(store:)
      @store = store
    end

    # Opens a run (:collecting). `window` is the collector's window as data
    # ({ "last_sessions" => N } | { "since" => iso8601 }) — recorded so a report can
    # be read months later and still say what it looked at. -> Run.
    def create(agent_id:, window: {}, id: SecureRandom.uuid, at: nil)
      agent = agent_id.to_s
      raise Insika::ValidationError, "agent_id is required" if agent.empty?
      raise Insika::ValidationError, "agent_id must not contain ':'" if agent.include?(":")

      started = at || timestamp
      record = {
        "id" => id.to_s, "agent_id" => agent, "status" => "collecting",
        "window" => deep_stringify(window || {}), "findings" => [], "excluded" => 0,
        "started_at" => started, "finished_at" => nil, "error" => nil,
        "candidate" => nil, "candidates" => [], "gate" => nil, "cost" => nil,
        "decision" => nil
      }
      @store.set(SCOPE, key_for(agent, started, id), record)
      to_run(record)
    end

    # Closes a run with its findings. Empty findings -> :no_findings (a distinct
    # outcome from :completed — "we looked and it was clean" is a real answer, not a
    # failure). -> Run. ArgumentError if the run is already terminal.
    # `excluded` is how many turns the window dropped on purpose (synthetic
    # traffic) — recorded so a report never reads cleaner than the data was.
    def complete(id, findings:, excluded: 0)
      update(id) do |record|
        guard_open!(record)
        list = Array(findings).map { |f| deep_stringify(f.respond_to?(:to_h) ? f.to_h : f) }
        record["findings"] = list
        record["excluded"] = Integer(excluded)
        record["status"] = list.empty? ? "no_findings" : "completed"
        record["finished_at"] = timestamp
      end
    end

    # Closes a run as :failed, recording the error. -> Run.
    def fail(id, error:)
      update(id) do |record|
        guard_open!(record)
        record["status"] = "failed"
        record["error"] = error.to_s
        record["finished_at"] = timestamp
      end
    end

    # the proposal's lifecycle -------------------------------

    # Attaches the candidate(s) under gate and moves the run to :gating. Only a
    # `completed` run can be gated: a report with no findings has nothing to propose
    # from, and a failed one never finished looking.
    #
    # `candidate:` (one) and `candidates:` (a panel) are the same call — the panel is
    # recorded before the gate runs so the Studio can show WHAT is being scored while
    # it is being scored, which is minutes of real replay. No winner is claimed yet:
    # `candidate` stays nil until `gated` says which one it is. -> Run.
    def gating(id, candidate: nil, candidates: nil)
      panel = Array(candidates || [candidate].compact)
      raise Insika::ValidationError, "a candidate is required to gate" if panel.empty?

      update(id) do |record|
        unless record["status"] == "completed"
          raise ArgumentError, "run #{record['id']} is #{record['status']}, expected completed"
        end

        record["candidates"] = panel.map { |c| entry_for(c) }
        record["candidate"] = nil
        record["gate"] = nil
        record["status"] = "gating"
      end
    end

    # Records the gate's verdict. A PASS parks the run at :awaiting_approval — a
    # human still has to say yes, which is the product and not a formality. A
    # FAIL is terminal as :rejected, with the gate report as the stated reason: the
    # same finding must re-surface with new evidence before anything is proposed
    # again, so there is no silent retry loop.
    #
    # `report` is the WINNER's (or, when nothing survived, the most informative
    # refusal). `panel` is every scored entry — the store attaches it as-is and picks
    # the winning candidate out of it by id. Which candidate WON is the caller's
    # ranking decision; this store does not rank, it records. -> Run.
    def gated(id, report:, panel: nil, cost: nil)
      update(id) do |record|
        unless record["status"] == "gating"
          raise ArgumentError, "run #{record['id']} is #{record['status']}, expected gating"
        end

        gate = deep_stringify(report.respond_to?(:to_h) ? report.to_h : report)
        record["candidates"] = panel.map { |e| entry_for(e) } if panel
        record["candidate"] = winning_candidate(record, gate)
        record["gate"] = gate
        record["cost"] = deep_stringify(cost.respond_to?(:to_h) ? cost.to_h : cost) if cost
        if gate["passed"]
          record["status"] = "awaiting_approval"
        else
          record["status"] = "rejected"
          record["decision"] = { "by" => "gate", "at" => timestamp, "note" => gate["reason"] }
          record["finished_at"] = timestamp
        end
      end
    end

    # The operator's answer to a gated proposal. `applied` is recorded only after the
    # writes land, so a crash between the two leaves the run awaiting approval and
    # the operator re-approves — replaying a write that is already versioned and
    # idempotent-ish beats recording a lie. -> Run.
    def resolve(id, decision:, operator: nil, note: nil)
      target = decision.to_sym
      unless %i[applied rejected].include?(target)
        raise Insika::ValidationError, "invalid decision: #{decision} (applied|rejected)"
      end

      update(id) do |record|
        unless record["status"] == "awaiting_approval"
          raise ArgumentError, "run #{record['id']} is #{record['status']}, expected awaiting_approval"
        end

        record["status"] = target.to_s
        record["decision"] = { "by" => (Coercion.presence(operator) || "operator").to_s,
                               "at" => timestamp, "note" => Coercion.presence(note) }.compact
        record["finished_at"] = timestamp
      end
    end

    # -> [Run] every run parked on a human, most recent first. What the Studio badges.
    def awaiting_approval(limit: 20)
      recent(limit: 200).select(&:awaiting_approval?).first(limit)
    end

    # -> Run | nil. O(n) scan over the scope (the key carries agent+timestamp, so
    # there is no index by id): one node, local SQLite, runs are operator-paced.
    def find(id)
      key = key_for_id(id)
      key && to_run(@store.get(SCOPE, key))
    end

    # -> [Run] for one agent, MOST RECENT FIRST, capped by `limit`.
    def for_agent(agent_id, limit: nil)
      keys = @store.list(SCOPE, "#{KEY_PREFIX}#{agent_id}:").reverse
      keys = keys.first(limit) if limit
      keys.filter_map { |k| to_run(@store.get(SCOPE, k)) }
    end

    # -> Run | nil (the agent's most recent run, whatever its status).
    def latest_for(agent_id) = for_agent(agent_id, limit: 1).first

    # -> [Run] across every agent, most recent first, capped.
    def recent(limit: 20)
      @store.list(SCOPE, KEY_PREFIX)
            .filter_map { |k| to_run(@store.get(SCOPE, k)) }
            .sort_by { |r| r.started_at.to_s }.reverse.first(limit)
    end

    private

    # One panel row: `{ candidate:, proposers: [], gate: }`. A bare Candidate (phase
    # C, an operator's own payload, an older record) is wrapped into the same shape,
    # so every reader has ONE thing to read and the two eras of this record do not
    # each need a branch in the Studio.
    def entry_for(value)
      raw = deep_stringify(value.respond_to?(:to_h) ? value.to_h : value)
      return raw if raw.key?("candidate")

      { "candidate" => raw, "proposers" => [raw["proposer"]].compact, "gate" => nil }
    end

    # The candidate the winning report belongs to, matched by id. A report whose
    # candidate is not in the panel (an older record, a hand-built payload) leaves
    # whatever was already there rather than inventing a winner.
    def winning_candidate(record, gate)
      match = Array(record["candidates"]).find do |entry|
        (entry["candidate"] || {})["id"] == gate["candidate_id"]
      end
      match ? match["candidate"] : record["candidate"]
    end

    def key_for(agent, started_at, id) = "#{KEY_PREFIX}#{agent}:#{started_at}:#{id}"

    # The id is the key's last segment; scanning is the price of keeping the key
    # chronological (which is what every read except `find` actually wants).
    def key_for_id(id)
      suffix = ":#{id}"
      @store.list(SCOPE, KEY_PREFIX).find { |k| k.end_with?(suffix) }
    end

    def update(id)
      key = key_for_id(id)
      raise Insika::NotFoundError, "refinement run not found: #{id}" if key.nil?

      record = @store.get(SCOPE, key)
      raise Insika::NotFoundError, "refinement run not found: #{id}" if record.nil?

      yield record
      @store.set(SCOPE, key, record)
      to_run(record)
    end

    def guard_open!(record)
      return if record["status"] == "collecting"

      raise ArgumentError, "run #{record['id']} is already #{record['status']}"
    end

    def to_run(record)
      return nil if record.nil?

      Run.new(
        id: record["id"], agent_id: record["agent_id"],
        status: record["status"].to_sym, window: record["window"] || {},
        findings: record["findings"] || [], excluded: record["excluded"] || 0,
        started_at: record["started_at"], finished_at: record["finished_at"],
        error: record["error"],
        candidate: record["candidate"], candidates: record["candidates"] || [],
        gate: record["gate"], cost: record["cost"], decision: record["decision"]
      )
    end

    def timestamp = Time.now.utc.iso8601
  end
end

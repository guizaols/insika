# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # the schedule records of the follow-up feature. The store owns
  # the `pending|fired|cancelled|blocked` states (never written by a consumer —
  # the task_store.rb state-machine idiom) and the (customer, reason) scans.
  # It holds no policy (C2) and no contact cells (C3).
  #
  # States:
  #   pending -> fired | cancelled | blocked
  # `fired` is set ONLY inside the same transaction that created the synthetic
  # task (D5 — the record and the turn commit together or together fail); a
  # `blocked` record carries `blocked_reason` — auditable, never silent.
  #
  # Record key: "<tenant>:<agent>:<customer>:<at>:#{uuid}" — per-customer /
  # per-agent scans are prefixes, and the scheduled `at` lives in the key so a
  # fired record keeps its scheduled time for the A/B card. Blank tenant -> the
  # literal "platform" (outcome_store.rb's rule — contact, follow-up and
  # outcome keys share one tenant segment so the purge prefix scans line up).
  class FollowupStore
    SCOPE = "followups"
    STATUSES = %w[pending fired cancelled blocked].freeze

    Record = Data.define(:id, :tenant, :agent, :customer, :session_id, :at,
                         :reason, :arm, :status, :task_id, :blocked_reason,
                         :transport, :created_at, :updated_at, :fired_at)

    def initialize(store:)
      @store = store
    end

    # -> Record (status :pending). `at` must be a future ISO8601 (a Time or an
    # ISO8601 string — ValidationError otherwise, "the follow-up would already
    # be due"). The caller decided the arm (C1) and the transport (C7).
    def create(tenant:, agent:, customer:, session_id:, at:, reason:, arm:,
               transport: nil, id: SecureRandom.uuid, now: Time.now.utc)
      time = parse_at(at)
      if time <= now
        raise Insika::ValidationError,
              "follow-up #{id.inspect} would already be due (at #{time.iso8601} <= now)"
      end
      if (prior = pending_for(tenant: tenant, agent: agent, customer: customer, reason: reason))
        raise Insika::ValidationError,
              "a follow-up for (customer #{customer.inspect}, reason #{reason.inspect}) is already " \
              "pending: #{prior.id}"
      end

      time = time.utc.iso8601
      record = { "id" => id.to_s, "tenant" => tenant_id(tenant), "agent" => agent.to_s,
                 "customer" => customer.to_s, "session_id" => session_id.to_s,
                 "at" => time, "reason" => reason.to_s, "arm" => arm.to_s,
                 "status" => "pending", "task_id" => nil, "blocked_reason" => nil,
                 "transport" => transport.to_s, "created_at" => now.iso8601,
                 "updated_at" => now.iso8601, "fired_at" => nil }
      @store.set(SCOPE, key_for(record), record)
      to_record(record)
    end

    # -> Record; NotFoundError on a nonexistent id. The only path out of
    # pending besides the engine's fired/blocked. Idempotent: an
    # already-cancelled record returns as-is (a repeat of the same call is not
    # an error).
    def cancel(id:, now: Time.now.utc)
      mutate(id, now) do |record|
        status = record["status"]
        unless %w[pending cancelled].include?(status)
          raise ArgumentError, "follow-up #{id}: cannot cancel a #{status} record"
        end

        record["status"] = "cancelled"
      end
    end

    # The engine's atomic claim: pending -> fired, WITH task_id. Read-check-
    # write inside Store#transaction (D5 — the record and the task commit
    # together). A second claim raises. `fired_at` stamps WHEN the fire
    # happened — the frequency ceiling and the A/B card count FIRES, never the
    # scheduled time (a record booked days ago and fired after a tick outage
    # must still count against the cap).
    def transition_fired(id:, task_id:, now: Time.now.utc)
      mutate(id, now) do |record|
        raise ArgumentError, "follow-up #{id}: not pending (#{record['status']}) — it fires once" unless record["status"] == "pending"

        record["status"] = "fired"
        record["task_id"] = task_id.to_s
        record["fired_at"] = now.utc.iso8601
      end
    end

    # pending -> blocked, with the failing rule name. -> Record
    def block(id:, reason:, now: Time.now.utc)
      mutate(id, now) do |record|
        raise ArgumentError, "follow-up #{id}: not pending (#{record['status']}) — only a pending record blocks" unless record["status"] == "pending"

        record["status"] = "blocked"
        record["blocked_reason"] = reason.to_s
      end
    end

    # -> Record | nil
    def find(id)
      record = @store.get(SCOPE, key_for_id(id))
      record && to_record(record)
    end

    # pending AND at <= now, oldest first (at, then id — determinism).
    def due(now: Time.now.utc)
      cutoff = now.iso8601
      @store.list(SCOPE).filter_map do |k|
        record = @store.get(SCOPE, k)
        next unless record && record["status"] == "pending" && record["at"].to_s <= cutoff

        to_record(record)
      end.sort_by { |r| [r.at.to_s, r.id] }
    end

    # ALL records of one (tenant, agent) — the Follow-ups page's read (C10),
    # lexicographic (the scheduled at first, so a fired record keeps its
    # position for the A/B card).
    def for_agent(tenant:, agent:)
      prefix = "#{tenant_id(tenant)}:#{agent}:"
      @store.list(SCOPE).filter_map do |k|
        next unless k.start_with?(prefix)

        to_record(@store.get(SCOPE, k))
      end
    end

    # The dedup scans (D7): the OLDEST pending record of the pair (nil when
    # none) and how many fired records of the customer fall inside the window
    # (the frequency gate). `pending_for` scans the pair's keys in key order —
    # the key embeds the scheduled `at` and the id, so the first pending record
    # found IS the oldest pending.
    def pending_for(tenant:, agent:, customer:, reason:)
      pending_record_for(tenant: tenant, agent: agent, customer: customer, reason: reason)
    end

    def pending_for?(tenant:, agent:, customer:, reason:)
      !pending_record_for(tenant: tenant, agent: agent, customer: customer, reason: reason).nil?
    end

    def fired_in_window(tenant:, customer:, since:)
      boundary = since.iso8601
      count = 0
      @store.list(SCOPE).each do |k|
        record = @store.get(SCOPE, k)
        next unless record
        next unless record["status"] == "fired"
        next unless record["tenant"] == tenant_id(tenant)
        next unless record["customer"] == customer.to_s
        # the frequency gate counts FIRES, never the scheduled time — a record
        # booked long ago and fired after a backlog still lands in the window.
        next unless record["fired_at"].to_s >= boundary

        count += 1
      end
      count
    end

    # Purge/prune (C11 — the LGPD footprint): one customer's records; a
    # tenant's; records older than the cutoff — TERMINAL (fired/cancelled/
    # blocked) OR pendings past their at (a zombie that will never fire;
    # retention ages it out rather than firing late). All count-returning and
    # nil-safe.

    # cancels every PENDING record of the customer inside ONE
    # transaction — the opt-out discipline (D2: a half-cancelled opt-out is
    # the spam bug). Blocked/fired records are never touched. -> count
    # cancelled.
    def cancel_pending_for(tenant:, customer:)
      count = 0
      @store.transaction do
        @store.list(SCOPE).each do |k|
          record = @store.get(SCOPE, k)
          next unless record && record["status"] == "pending"
          next unless record["tenant"] == tenant_id(tenant)
          next unless record["customer"] == customer.to_s

          record["status"] = "cancelled"
          record["updated_at"] = Time.now.utc.iso8601
          @store.set(SCOPE, k, record)
          count += 1
        end
      end
      count
    end

    def purge_customer(tenant:, customer:)
      removed = 0
      @store.list(SCOPE).each do |k|
        record = @store.get(SCOPE, k)
        next unless record && record["tenant"] == tenant_id(tenant)
        next unless record["customer"] == customer.to_s

        @store.delete(SCOPE, k)
        removed += 1
      end
      removed
    end

    def purge(tenant:)
      prefix = "#{tenant_id(tenant)}:"
      keys = @store.list(SCOPE).select { |k| k.start_with?(prefix) }
      keys.each { |k| @store.delete(SCOPE, k) }
      keys.size
    end

    # -> count removed.
    def delete_older_than(time)
      cutoff = time.utc.iso8601
      removed = 0
      @store.list(SCOPE).each do |k|
        record = @store.get(SCOPE, k)
        next unless record

        terminal = record["status"] != "pending"
        # TERMINAL records age by their updated_at; a PENDING record is a
        # zombie when its scheduled `at` has passed (it will never fire —
        # retention ages it out rather than firing late).
        next unless (terminal && record["updated_at"].to_s < cutoff) ||
                    (!terminal && record["at"].to_s < cutoff)

        @store.delete(SCOPE, k)
        removed += 1
      end
      removed
    end

    private

    # -> Record | nil — the OLDEST pending record of the (agent, customer,
    # reason) pair, if any (the dedup rule holds at creation AND at fire: the
    # firer only fires the oldest pending per pair).
    def pending_record_for(tenant:, agent:, customer:, reason:)
      prefix = "#{tenant_id(tenant)}:#{agent}:"
      @store.list(SCOPE).each do |k|
        next unless k.start_with?(prefix)

        record = @store.get(SCOPE, k)
        next unless record && record["status"] == "pending"
        next unless record["customer"] == customer.to_s
        next unless record["reason"] == reason.to_s

        return to_record(record)
      end
      nil
    end

    def mutate(id, now)
      @store.transaction do
        record = @store.get(SCOPE, key_for_id(id))
        raise Insika::NotFoundError, "follow-up not found: #{id}" if record.nil?

        yield record
        record["updated_at"] = now.utc.iso8601
        @store.set(SCOPE, key_for_id(id), record)
        to_record(record)
      end
    end

    def key_for(record)
      # tenant + agent + customer + the scheduled at + id: per-customer /
      # per-agent scans are prefixes, the at-first ordering keeps a fired
      # record at its scheduled position (the A/B card's lexicographic list).
      "#{record['tenant']}:#{record['agent']}:#{record['customer']}:#{record['at']}:#{record['id']}"
    end

    def key_for_id(id)
      # the id is the LAST segment, so a find is a suffix match over the
      # scope's keys (there is no stable prefix for an id alone).
      @store.list(SCOPE).find { |k| k.end_with?(":#{id}") }
    end

    def parse_at(at)
      case at
      when Time then at.utc
      else
        begin
          Time.iso8601(at.to_s).utc
        rescue ArgumentError
          raise Insika::ValidationError, "follow-up `at` must be an ISO8601 time, got: #{at.inspect}"
        end
      end
    end

    def tenant_id(tenant)
      t = tenant.to_s
      t.empty? ? "platform" : t
    end

    def to_record(rec)
      return nil if rec.nil?

      Record.new(id: rec["id"], tenant: rec["tenant"], agent: rec["agent"],
                 customer: rec["customer"], session_id: rec["session_id"],
                 at: rec["at"], reason: rec["reason"], arm: rec["arm"],
                 status: rec["status"], task_id: rec["task_id"],
                 blocked_reason: rec["blocked_reason"], transport: rec["transport"],
                 created_at: rec["created_at"], updated_at: rec["updated_at"],
                 fired_at: rec["fired_at"])
    end
  end
end

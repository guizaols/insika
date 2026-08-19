# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # the per-agent schedule rows of the recurring feature — one
  # row per declared schedule, keyed `tenant:agent:id`, holding BOTH the
  # declaration (a copy of the profile's `schedules` entry — the engine reads
  # the store, never the profile, on the fire path) and the runtime state
  # (`next_fire_at`, `last_run_at`, `last_task_id`, `last_skip`).
  #
  # The row is a DERIVED record: the profile declaration is the config (the
  # DSL, the API, the Studio all edit the profile); the ScheduleEngine
  # reconciles rows with declarations at each pass. The engine OWNS the
  # runtime writes — `transition_fire`/`mark_skip` are called only inside the
  # engine's transaction (the D5 discipline), never by a consumer. A row that
  # is no longer declared is deleted (no zombie schedules); a row whose
  # declaration is malformed is deleted too — a broken schedule must not keep
  # firing with stale text (the doctor names it).
  #
  # Multi-worker at-most-once rides Store#transaction: the pass re-reads the
  # row inside the transaction, so two workers serialize on the backend lock
  # and only one advances `next_fire_at`.
  class ScheduleStore
    SCOPE = "schedules"

    Record = Data.define(:id, :tenant, :agent, :every, :cron, :tz, :message,
                         :session_mode, :session_id, :overrides, :enabled,
                         :next_fire_at, :last_run_at, :last_task_id, :last_skip,
                         :created_at, :updated_at)

    def initialize(store:)
      @store = store
    end

    # Reconcile: upsert the declaration's row, or delete it when the
    # declaration is gone/malformed. Called by the engine inside its pass
    # transaction. A NEW or CHANGED declaration recomputes `next_fire_at`
    # (the trigger lattice starts fresh); an unchanged row keeps its.
    def sync_declared(tenant:, agent:, schedules: nil, now: Time.now.utc)
      kept = []
      Array(schedules).each do |declaration|
        schedule = Insika::Schedule.parse(declaration)
        next if schedule.nil? # malformed — dropped, the doctor names it

        keep = upsert(tenant: tenant, agent: agent, schedule: schedule, now: now)
        kept << schedule.id if keep
      end

      # drop rows the agent no longer declares
      prefix = "#{tenant_id(tenant)}:#{agent}:"
      @store.list(SCOPE).each do |k|
        next unless k.start_with?(prefix)
        next if kept.include?(k.split(":").last)

        @store.delete(SCOPE, k)
      end
      kept
    end

    # -> Record | nil
    def find(tenant:, agent:, id:)
      record = @store.get(SCOPE, key(tenant, agent, id))
      record && to_record(record)
    end

    # -> [Record] — one agent's rows (the Studio's read), lexicographic.
    def for_agent(tenant:, agent:)
      prefix = "#{tenant_id(tenant)}:#{agent}:"
      @store.list(SCOPE).filter_map do |k|
        next unless k.start_with?(prefix)

        to_record(@store.get(SCOPE, k))
      end
    end

    # -> [Record] — every row (the Studio grid, the engine pass).
    def all
      @store.list(SCOPE).filter_map { |k| to_record(@store.get(SCOPE, k)) }
    end

    # -> [Record] — enabled AND due, oldest first (determinism). A row whose
    # next_fire_at is nil (a cron that can never fire) is never due.
    def due(now: Time.now.utc)
      cutoff = now.iso8601
      all.select { |r| r.enabled && !r.next_fire_at.to_s.empty? && r.next_fire_at.to_s <= cutoff }
         .sort_by { |r| [r.next_fire_at.to_s, r.id] }
    end

    # The engine's atomic fire claim — the LAST step of the fire's
    # transaction: advance the lattice, stamp the run, clear the skip.
    # Callers pass `id` and the engine's OWN transaction encloses this.
    def transition_fire(id:, tenant:, agent:, task_id:, next_fire_at:, now: Time.now.utc)
      mutate(tenant, agent, id, now) do |record|
        record["last_run_at"] = now.utc.iso8601
        record["last_task_id"] = task_id.to_s
        record["next_fire_at"] = next_fire_at.iso8601
        record["last_skip"] = nil
      end
    end

    # The visible skip — recorded, never silent: `next_fire_at` advances
    # (the window is skipped, not queued) and `last_skip` names why.
    def mark_skip(id:, tenant:, agent:, reason:, next_fire_at:, now: Time.now.utc)
      mutate(tenant, agent, id, now) do |record|
        record["last_skip"] = { "at" => now.utc.iso8601, "reason" => reason.to_s }
        record["next_fire_at"] = next_fire_at.iso8601
      end
    end

    def delete(tenant:, agent:, id:)
      @store.delete(SCOPE, key(tenant, agent, id))
    end

    # -> count removed. The LGPD sweep (a tenant's schedules die with it).
    def purge(tenant:)
      prefix = "#{tenant_id(tenant)}:"
      keys = @store.list(SCOPE).select { |k| k.start_with?(prefix) }
      keys.each { |k| @store.delete(SCOPE, k) }
      keys.size
    end

    private

    # Create or update ONE row from the declaration, recomputing next_fire_at
    # on create and on any trigger/definition change. -> the schedule id.
    def upsert(tenant:, agent:, schedule:, now:)
      k = key(tenant, agent, schedule.id)
      record = @store.get(SCOPE, k)
      return schedule.id if record && !changed?(record, schedule)

      next_fire_at = initial_next_fire(schedule, now)
      row = {
        "id" => schedule.id, "tenant" => tenant_id(tenant), "agent" => agent.to_s,
        "every" => schedule.every, "cron" => schedule.cron, "tz" => schedule.tz,
        "message" => schedule.message, "session_mode" => schedule.session_mode,
        "session_id" => schedule.session_id, "overrides" => schedule.overrides,
        "enabled" => schedule.enabled,
        "next_fire_at" => next_fire_at&.iso8601,
        "last_run_at" => record&.dig("last_run_at"),
        "last_task_id" => record&.dig("last_task_id"),
        "last_skip" => record&.dig("last_skip"),
        "created_at" => record ? record["created_at"] : now.iso8601,
        "updated_at" => now.iso8601
      }
      @store.set(SCOPE, k, row)
      schedule.id
    end

    # Does the row's DECLARATION differ from the schedule? (runtime state is
    # never part of the comparison.)
    def changed?(record, schedule)
      record["cron"] != schedule.cron || record["every"] != schedule.every ||
        record["tz"] != schedule.tz || record["message"] != schedule.message ||
        record["session_mode"] != schedule.session_mode ||
        record["session_id"] != schedule.session_id ||
        record["overrides"] != schedule.overrides ||
        record["enabled"] != schedule.enabled
    end

    # The first fire after `now` for a schedule that has none yet: for `every`,
    # one interval out; for cron, the next expression match. nil (a cron that
    # can never fire) makes the row never due — `due` ignores a nil.
    def initial_next_fire(schedule, now)
      if schedule.every
        now + schedule.every
      else
        Insika::Cron.new(schedule.cron).next_after(now, tz: schedule.tz)
      end
    end

    def mutate(tenant, agent, id, now)
      @store.transaction do
        record = @store.get(SCOPE, key(tenant, agent, id))
        raise Insika::NotFoundError, "schedule not found: #{tenant}:#{agent}:#{id}" if record.nil?

        yield record
        record["updated_at"] = now.utc.iso8601
        @store.set(SCOPE, key(tenant, agent, id), record)
        to_record(record)
      end
    end

    def key(tenant, agent, id)
      "#{tenant_id(tenant)}:#{agent.to_s}:#{id.to_s}"
    end

    def tenant_id(tenant)
      t = tenant.to_s
      t.empty? ? "platform" : t
    end

    def to_record(rec)
      return nil if rec.nil?

      Record.new(id: rec["id"], tenant: rec["tenant"], agent: rec["agent"],
                 every: rec["every"], cron: rec["cron"], tz: rec["tz"],
                 message: rec["message"], session_mode: rec["session_mode"],
                 session_id: rec["session_id"], overrides: rec["overrides"],
                 enabled: rec["enabled"] != false,
                 next_fire_at: rec["next_fire_at"],
                 last_run_at: rec["last_run_at"],
                 last_task_id: rec["last_task_id"], last_skip: rec["last_skip"],
                 created_at: rec["created_at"], updated_at: rec["updated_at"])
    end
  end
end
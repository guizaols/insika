# frozen_string_literal: true

require "time"

module Insika
  # the tick-driven FIRER of recurring schedules: the engine's
  # fourth duty (after the outbox drain, retention/funnel and the follow-up
  # firer). One pass per claim window (the followup/funnel idiom); each due
  #   schedule is claimed transactionally — re-read inside its own transaction,
  #   so two workers racing a window serialize on the backend lock and exactly
  #   one fires (the multi-worker at-most-once claim, per row).
  #
  # Gating order:
  #
  #   declared? (reconciled from the profiles) -> enabled + due -> no-catch-up
  #   (a window older than one claim window is MISSED, recorded, never
  #   replayed) -> overlap (the last task still live) -> budget (a hard
  #   window at/over cap) -> FIRE.
  #
  # Skips are DATA, never silent: `last_skip { at, reason }` on the row, for
  # the Studio. The engine never queues — a skipped window advances the
  # schedule's lattice. The turn it creates is delivered by the existing
  # pipeline (it holds no channel code, like the FollowupEngine).
  class ScheduleEngine
    SCOPE = "schedule_fire"
    KEY = "claim"
    DEFAULT_WINDOW = 300 # seconds; one firing worker per window
    TENANT = "platform"  # the engine's single-tenant default (ledger rules)

    ACTIVE_STATUSES = %i[queued running waiting paused].freeze

    def initialize(store:, schedule_store:, task_store:, session_store:,
                   profiles:, executor:, budget_ledger: nil, event_stream: nil,
                   window: DEFAULT_WINDOW, now: nil)
      @store = store
      @schedule_store = schedule_store
      @task_store = task_store
      @session_store = session_store
      @profiles = profiles
      @executor = executor
      @budget_ledger = budget_ledger
      @event_stream = event_stream
      @window = window
      @now = now
    end

    # -> { claimed: false }
    #  | { claimed: true, fired: N, skipped: N, errors: N,
    #      skip_reasons: { "reason" => N } }
    # A StoreError on ONE schedule aborts THAT schedule's transaction
    # (rescued, counted, the loop continues) — a broken row must not hold the
    # other schedules' runs hostage.
    def run
      now_time = @now || Time.now.utc
      return { claimed: false } unless claim_window(now_time)

      sync_from_profiles(now_time)

      fired = 0
      skipped = 0
      errors = 0
      reasons = Hash.new(0)

      @schedule_store.due(now: now_time).each do |record|
        begin
          outcome = fire_record(record, now_time)
          case outcome
          when :fired then fired += 1
          when Array
            # a skip is recorded on the row (never silent) and counted here.
            skipped += 1
            reasons[outcome[1].to_s] += 1
          end
        rescue StandardError
          # a broken schedule must not hold the other schedules' runs
          # hostage — its own transaction already rolled back.
          errors += 1
        end
      end

      { claimed: true, fired: fired, skipped: skipped, errors: errors,
        skip_reasons: reasons }
    end

    private

    # Reconciliation: the PROFILES are the source of the declarations (DSL /
    # API / Studio); the store rows are the derived view the fire path reads.
    # One pass: drop rows whose agent no longer exists, then upsert each
    # profile's declared schedules (and drop each agent's undeclared rows).
    def sync_from_profiles(now_time)
      ids = @profiles.ids.map(&:to_s)
      @store.transaction do
        @schedule_store.all.each do |row|
          @schedule_store.delete(tenant: row.tenant, agent: row.agent, id: row.id) unless ids.include?(row.agent)
        end
        @profiles.all.each do |profile|
          schedules = profile.respond_to?(:schedules) ? profile.schedules : nil
          @schedule_store.sync_declared(tenant: TENANT, agent: profile.id,
                                        schedules: schedules, now: now_time)
        end
      end
    end

    # -> :fired | [:skipped, reason] — claimed per row, inside ONE
    # transaction: the re-read, the gates, the task creation and the lattice
    # advance commit together or not at all — and the SPAWN happens AFTER the
    # commit, so a spawn failure never unwinds the fire (the durable :queued
    # task is the recovery sweep's to handle). `next`, never `return`, inside
    # the block (a non-local return skips the backend's COMMIT).
    def fire_record(record, now_time)
      task = nil
      outcome = nil
      spawn_profile = nil
      @store.transaction do
        current = @schedule_store.find(tenant: record.tenant, agent: record.agent, id: record.id)
        # a racing worker already advanced/deleted the row — nothing for this pass.
        unless current
          outcome = [:skipped, :stale]
          next
        end
        unless current.enabled
          outcome = [:skipped, :stale]
          next
        end
        next_at = Time.iso8601(current.next_fire_at.to_s)
        unless next_at <= now_time
          outcome = [:skipped, :stale] # the racing worker claimed the window
          next
        end

        # the no-catch-up policy: a window older than ONE claim window is
        # MISSED, not replayed — the lattice advances and the row records it.
        if next_at < now_time - @window
          @schedule_store.mark_skip(id: current.id, tenant: current.tenant,
                                    agent: current.agent, reason: :late,
                                    next_fire_at: next_after(current, now_time),
                                    now: now_time)
          outcome = [:skipped, :late]
          next
        end

        # overlap: the previous run is still live — skip + record, never a queue.
        if overlap?(current)
          @schedule_store.mark_skip(id: current.id, tenant: current.tenant,
                                    agent: current.agent, reason: :overlap,
                                    next_fire_at: next_after(current, now_time),
                                    now: now_time)
          outcome = [:skipped, :overlap]
          next
        end

        profile = @profiles.fetch(current.agent)
        if profile && budget_exhausted?(profile, current, now_time)
          @schedule_store.mark_skip(id: current.id, tenant: current.tenant,
                                    agent: current.agent, reason: :budget,
                                    next_fire_at: next_after(current, now_time),
                                    now: now_time)
          outcome = [:skipped, :budget]
          next
        end

        task = commit_run(current, profile, now_time)
        spawn_profile = derived_profile(current, profile)
        outcome = :fired
      end
      return outcome || [:skipped, :stale] unless task

      # AFTER the commit: the spawn. A failure propagates to the pass (counted
      # as an error) — the fire already committed, and the :queued task is
      # recovered by the tick's sweep.
      @executor.spawn_in_session(task, profile: spawn_profile)
      emit_fired(record, task.id)
      :fired
    end

    # The atomic claim inside the pass's transaction: the task and the
    # schedule's state (last run, task id, next fire) commit together or not
    # at all (the follow-up firer's D5 shape).
    def commit_run(current, profile, now_time)
      session_id = resolve_session(current)
      command = {
        "type" => "scheduled_run",
        "session_id" => session_id,
        "payload" => {
          "agent" => current.agent, "session_id" => session_id,
          "message" => current.message, "origin" => Insika::MessageOrigin::SCHEDULED,
          "schedule_id" => current.id
        },
        "meta" => { "tenant" => current.tenant, "transport" => "schedule" }
      }
      task = @task_store.create(command: command, session_id: session_id)
      @schedule_store.transition_fire(id: current.id, tenant: current.tenant,
                                      agent: current.agent, task_id: task.id,
                                      next_fire_at: next_after(current, now_time),
                                      now: now_time)
      task
    end

    # -> session_id for the run. session_mode "new" = a fresh session per run
    # (the report case); "fixed" = the declared session, created on first run
    # (the "standing assistant" case).
    def resolve_session(current)
      if current.session_mode == "fixed"
        sid = current.session_id.to_s
        sid = "sched-#{current.agent}-#{current.id}" if sid.empty?
        @session_store.create(id: sid) unless @session_store.find(sid)
        sid
      else
        @session_store.create.id
      end
    end

    # The profile the turn runs on: the base profile with the schedule's
    # overrides merged (per-schedule ceiling, never a store-wide change). The
    # base is untouched — a second schedule cannot see a sibling's overrides.
    def derived_profile(current, base)
      overrides = current.overrides
      return base if overrides.nil? || overrides.empty?

      limits = base.limits.dup
      limits[:turn_timeout] = overrides["turn_timeout"] if overrides["turn_timeout"]
      limits[:max_tool_calls] = overrides["max_tool_calls"] if overrides["max_tool_calls"]
      Insika::AgentProfile.build(**base.to_h.merge(limits: limits,
                                                   model: overrides["model"] || base.model))
    end

    # The next lattice point after `now`: for `every`, the next interval
    # boundary; for cron, the next expression occurrence in the schedule's tz.
    # nil (a cron that can never fire) makes the row never due again.
    def next_after(current, now_time)
      if current.every
        base = Time.iso8601(current.next_fire_at.to_s)
        base + ((now_time - base).to_i / current.every + 1) * current.every
      else
        Insika::Cron.new(current.cron).next_after(now_time, tz: current.tz)
      end
    end

    def overlap?(current)
      task_id = current.last_task_id.to_s
      return false if task_id.empty?

      task = @task_store.find(task_id)
      task && ACTIVE_STATUSES.include?(task.status)
    end

    # A HARD budget at/over a window cap = skip (the edge would fail the turn
    # anyway — this refuses to even queue it). A soft budget crosses and runs;
    # the ledger warns as usual. Mirror of EdgeLimiter#budget_windows — the
    # SOFT half is the edge's, this is the schedule gate's.
    def budget_exhausted?(profile, current, now_time)
      budget = profile.respond_to?(:budget) ? profile.budget : nil
      return false if budget.nil? || @budget_ledger.nil?

      soft = budget["soft"] == true
      %i[daily monthly].any? do |window|
        cap = budget[window.to_s].to_i
        next false unless cap.positive?

        spent = @budget_ledger.current(tenant: current.tenant, agent: current.agent,
                                       now: now_time)[window]
        !soft && spent >= cap
      end
    end

    def emit_fired(record, task_id)
      return unless @event_stream

      @event_stream.emit(Insika::Event.new(
                           type: :schedule_fired,
                           data: { id: record.id, agent: record.agent, task_id: task_id },
                           meta: { tenant: record.tenant, at: Time.now.utc.iso8601 }
                         ))
    end

    # The claim window (the funnel_fold.rb idiom — read-check-write on one key
    # inside a transaction): the O(n) scans never ride the 60 s tick, and two
    # workers racing a pass serialize on the backend's lock.
    def claim_window(now_time)
      @store.transaction do
        current = @store.get(SCOPE, KEY)
        last = current && begin
          Time.iso8601(current["claimed_at"].to_s)
        rescue ArgumentError
          nil # a corrupted claim is not a claim — take the window
        end
        if last.nil? || (now_time - last) >= @window
          @store.set(SCOPE, KEY, { "claimed_at" => now_time.iso8601 })
          true
        else
          false
        end
      end
    end
  end
end
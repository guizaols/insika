# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # Called ONCE at boot, BEFORE accepting requests. Discovers
  # interrupted tasks and dispatches the resume through the SAME path as
  # ResumeTask — this component executes nothing, opens no Execution, changes no
  # status of resumable tasks. Just discovery + dispatch + marking of
  # unrecoverable tasks.
  #
  # Durability without an external job runner = stores +
  # recovery at boot. The "execution" half is the ResumeTask handler.
  #
  # `command_bus` is consumed only through the `dispatch(command)` contract.
  class Recovery
    SWEEP_SCOPE = "recovery"

    # The per-boot-generation sweep claim (RFC-0016 E2). N workers share one
    # store, and the sweep's "orphaned :running" test is per-process: a worker
    # booting while a sibling holds a live turn would see it as an orphan and
    # re-run it. So the TASK sweep runs once per boot generation — the first
    # worker to claim `boot_id` sweeps, the rest skip; a worker respawned
    # mid-generation skips too (its own orphans wait for the next generation).
    # Rides Store#transaction like every claim. nil/empty boot_id (single
    # process: DSL serve, scripts, tests) -> always true, every boot sweeps.
    def self.claim_sweep(store:, boot_id:)
      id = boot_id.to_s
      return true if id.empty?

      store.transaction do
        key = "sweep:#{id}"
        if store.get(SWEEP_SCOPE, key).nil?
          store.set(SWEEP_SCOPE, key, { "claimed_at" => Time.now.utc.iso8601 })
          true
        else
          false
        end
      end
    end

    # checkpoint_store: needed to query `latest`. logger optional
    # (default nil -> silent in tests).
    def initialize(task_store:, checkpoint_store:, command_bus:, logger: nil)
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @command_bus = command_bus
      @logger = logger
    end

    # -> { resumed: [ids], failed: [ids] }
    # The initial sweep runs OUTSIDE the per-task rescue: a StoreError here
    # aborts the boot.
    #
    # stale_after (seconds, RFC-0019): the periodic tick's semantics instead of
    # boot's. Only :queued/:running tasks untouched for longer than that are
    # candidates — :waiting/:paused are idle by nature (a human wait), so
    # staleness cannot tell a live one from a dead one, and they stay boot
    # recovery's. The threshold exists because a live :running turn is bounded
    # by turn_timeout: anything older cannot be alive.
    def run(stale_after: nil)
      resumed = []
      failed = []
      # Ordered by created_at: tasks from the SAME session are reprocessed
      # in their original order. Global time ordering is harmless for standalone tasks.
      # 1) interrupted (crash mid-flight) -> resume from the checkpoint. Tick mode
      #    narrows this to :running — the only mid-flight state staleness can judge.
      running = stale_after ? @task_store.with_status(:running) : @task_store.running_or_interrupted
      sweep(running, stale_after).each { |task| process(task, resumed, failed, tick: !stale_after.nil?) }
      # 2) queued but never started (turn in the SessionActor queue at crash time)
      #    -> re-run from scratch (the same resume_task handles :queued). Without
      #    this, a :queued turn in the volatile queue would be lost on kill -9.
      sweep(@task_store.queued, stale_after).each { |task| process(task, resumed, failed, tick: !stale_after.nil?) }
      log(:info, "recovery finished: #{resumed.size} resumed, #{failed.size} failed")
      { resumed: resumed, failed: failed }
    end

    private

    # Boot mode (stale_after nil) takes the candidate list as-is; tick mode keeps
    # only tasks untouched past the threshold — the liveness gate of §4 item 3.
    def sweep(tasks, stale_after)
      tasks = tasks.sort_by(&:created_at)
      return tasks unless stale_after

      cutoff = Time.now.utc - stale_after
      tasks.select { |task| stale?(task, cutoff) }
    end

    def stale?(task, cutoff)
      Time.iso8601(task.updated_at.to_s) < cutoff
    rescue ArgumentError
      true # an unreadable timestamp is not proof of life — treat as stale
    end

    # Failing to resume ONE task does not bring down the boot: a non-store
    # dispatch/latest error -> mark :failed and continue. StoreError -> propagate
    # (aborts the boot).
    #
    # tick: true (RFC-0019) flips ONE rescue: a ValidationError from the dispatch
    # is ResumeTask's local liveness check ("task is running") — someone alive
    # owns it, the normal case on a timer, so the task is SKIPPED for the next
    # tick. At boot a ValidationError means corruption (nothing may be alive),
    # so it still fails the task there. This is the E2 trap defused in-process:
    # the tick must never murder a live turn with its own recovery.
    def process(task, resumed, failed, tick: false)
      # :queued never started (no checkpoint) but IS recoverable — ResumeTask
      # re-runs from the Command. An interrupted task requires a checkpoint;
      # without one, it is unrecoverable.
      if task.status == :queued || @checkpoint_store.latest(task.id)
        @command_bus.dispatch(resume_command(task.id))
        resumed << task.id
        log(:info, "resume dispatched: #{task.id}")
      else
        fail_task(task.id, class_name: "Insika::Error",
                           message: "unrecoverable: no checkpoint")
        failed << task.id
        log(:warn, "unrecoverable (no checkpoint): #{task.id}")
      end
    rescue Insika::StoreError
      raise
    rescue Insika::ValidationError => e
      # Boot keeps the old contract (corruption -> :failed); the tick skips.
      if tick
        log(:info, "skipped (alive elsewhere): #{task.id} — #{e.message}")
      else
        fail_task(task.id, class_name: e.class.name, message: e.message, stage: "recovery")
        failed << task.id unless failed.include?(task.id)
        log(:warn, "failed to resume #{task.id}: #{e.class}: #{e.message}")
      end
    rescue StandardError => e
      fail_task(task.id, class_name: e.class.name, message: e.message, stage: "recovery")
      failed << task.id unless failed.include?(task.id)
      log(:warn, "failed to resume #{task.id}: #{e.class}: #{e.message}")
    end

    # Transitions the task to :failed, writing the error into the open Execution
    # (if any). StoreError propagates (aborts the boot). ArgumentError is
    # absorbed: `paused -> failed` is not in the machine — the task stays in its
    # current state, but we still report it as failed in the summary. Do not
    # "fix" the machine here.
    def fail_task(id, class_name:, message:, stage: nil)
      error = { class: class_name, message: message }
      error[:stage] = stage if stage
      @task_store.transition(id, to: :failed, error: error)
    rescue Insika::StoreError
      raise
    rescue ArgumentError
      nil
    end

    def resume_command(task_id)
      # transport: :recovery identifies the origin (boot) in meta — auditing
      # (the field is a free Symbol).
      Insika::Command.build(:resume_task, { task_id: task_id }, transport: :recovery)
    end

    # Logging is pure observability: a logger failure must NEVER alter the
    # recovery flow (otherwise a buggy logger would corrupt the summary —
    # e.g. an id in resumed AND failed). We swallow any logger error.
    def log(level, message)
      @logger&.public_send(level, "[recovery] #{message}")
    rescue StandardError
      nil
    end
  end
end

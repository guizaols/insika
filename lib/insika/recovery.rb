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
    def run
      resumed = []
      failed = []
      # Ordered by created_at: tasks from the SAME session are reprocessed
      # in their original order. Global time ordering is harmless for standalone tasks.
      # 1) interrupted (crash mid-flight) -> resume from the checkpoint.
      @task_store.running_or_interrupted.sort_by(&:created_at).each { |task| process(task, resumed, failed) }
      # 2) queued but never started (turn in the SessionActor queue at crash time)
      #    -> re-run from scratch (the same resume_task handles :queued). Without
      #    this, a :queued turn in the volatile queue would be lost on kill -9.
      @task_store.queued.sort_by(&:created_at).each { |task| process(task, resumed, failed) }
      log(:info, "recovery finished: #{resumed.size} resumed, #{failed.size} failed")
      { resumed: resumed, failed: failed }
    end

    private

    # Failing to resume ONE task does not bring down the boot: a non-store
    # dispatch/latest error -> mark :failed and continue. StoreError -> propagate
    # (aborts the boot).
    def process(task, resumed, failed)
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

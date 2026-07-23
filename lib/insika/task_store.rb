# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # Domain store for tasks. Persists Tasks over an
  # injected Insika::Store, with the STATE MACHINE validated here: the store is
  # the only place status is written, so the
  # invariants live where the writes live. An invalid transition is a bug and raises
  # ArgumentError loud and early — this is how logical races are
  # detected without a lock.
  #
  # Each Execution is ONE attempt; retry/resume opens a new entry, never
  # overwrites.
  class TaskStore
    include Coercion

    SCOPE = "tasks"
    KEY_PREFIX = "task:"

    STATUSES = %i[queued running waiting paused completed failed cancelled].freeze

    # Valid transitions — anything outside this is a bug -> ArgumentError.
    TRANSITIONS = {
      # queued -> failed: a turn queued in the SessionActor may fail
      # at STARTUP (spawn error before the fiber) without ever running.
      queued: %i[running cancelled failed],
      running: %i[waiting paused completed failed cancelled],
      waiting: %i[running cancelled failed],
      paused: %i[running cancelled],
      completed: [], failed: [], cancelled: [] # terminal
    }.freeze

    Task      = Data.define(:id, :status, :command, :session_id, :executions,
                            :mailbox_state, :created_at, :updated_at)
    Execution = Data.define(:attempt, :started_at, :finished_at, :outcome, :error)

    def initialize(store:)
      @store = store
    end

    # -> Task (status :queued). command: Hash ({type:, payload:, meta:}) or
    # any object that responds to to_h (e.g. Insika::Command).
    # ArgumentError if the id already exists.
    def create(command:, session_id: nil, id: SecureRandom.uuid)
      key = key_for(id)
      raise ArgumentError, "task already exists: #{id}" unless @store.get(SCOPE, key).nil?

      now = timestamp
      record = {
        "id" => id.to_s,
        "status" => "queued",
        "command" => deep_stringify(command.respond_to?(:to_h) ? command.to_h : command),
        "session_id" => session_id&.to_s,
        "executions" => [],
        "mailbox_state" => { "pending" => [] },
        "created_at" => now,
        "updated_at" => now
      }
      @store.set(SCOPE, key, record)
      to_task(record)
    end

    # -> Task | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_task(record)
    end

    # -> Task; validates the state machine. NotFoundError if absent,
    # ArgumentError for a status outside the enum or an invalid transition.
    # If `error:` is provided AND there is an open Execution, it closes it in the same write
    # (Recovery path).
    def transition(id, to:, error: nil)
      record = fetch!(id)
      target = to.to_sym
      raise ArgumentError, "invalid status: #{to}" unless STATUSES.include?(target)

      from = record["status"].to_sym
      unless TRANSITIONS.fetch(from).include?(target)
        raise ArgumentError, "invalid transition: #{from} -> #{target}"
      end

      close_open_execution(record, outcome: target.to_s, error: error) if error
      record["status"] = target.to_s
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_task(record)
    end

    # -> Task; opens an Execution (attempt N+1). ArgumentError if one is already
    # open (a double attempt is a bug — one owner per task). Append-only.
    def begin_execution(id)
      record = fetch!(id)
      raise ArgumentError, "an open Execution already exists on task #{id}" if open_execution(record)

      record["executions"] += [{
        "attempt" => record["executions"].size + 1,
        "started_at" => timestamp,
        "finished_at" => nil,
        "outcome" => nil,
        "error" => nil
      }]
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_task(record)
    end

    # -> Task; closes the current Execution. ArgumentError if none is open.
    # Does NOT touch status (that is transition's job).
    def finish_execution(id, outcome:)
      record = fetch!(id)
      open = open_execution(record)
      raise ArgumentError, "no open Execution on task #{id}" if open.nil?

      open["finished_at"] = timestamp
      open["outcome"] = outcome.to_s
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_task(record)
    end

    # -> [Task] with one of the given statuses. O(n) scan at boot;
    # acceptable (one node, local SQLite).
    def with_status(*statuses)
      wanted = statuses.flatten
      @store.list(SCOPE, KEY_PREFIX).filter_map do |key|
        record = @store.get(SCOPE, key)
        next if record.nil?

        task = to_task(record)
        task if wanted.include?(task.status)
      end
    end

    # Interrupted (crashed mid-turn): have a checkpoint -> resume.
    def running_or_interrupted = with_status(:running, :waiting, :paused)

    # Queued but never started (turn in the SessionActor queue at the
    # crash) — no checkpoint; recovering = RUN from scratch (Recovery/ResumeTask).
    def queued = with_status(:queued)

    # -> enumerates ids without the "task:" prefix; without a block returns an Enumerator.
    def each_id
      return enum_for(:each_id) unless block_given?

      @store.list(SCOPE, KEY_PREFIX).each do |key|
        yield key.delete_prefix(KEY_PREFIX)
      end
    end

    private

    def key_for(id)
      "#{KEY_PREFIX}#{id}"
    end

    # NotFoundError if absent (nonexistent task -> 404). Backend StoreError
    # propagates without re-wrapping.
    def fetch!(id)
      record = @store.get(SCOPE, key_for(id))
      raise Insika::NotFoundError, "task not found: #{id}" if record.nil?

      record
    end

    # The open Execution is the last one with finished_at nil (one owner per task, so
    # there is at most one). Returns the raw Hash (mutable in-place for the RMW).
    def open_execution(record)
      last = record["executions"].last
      last if last && last["finished_at"].nil?
    end

    def close_open_execution(record, outcome:, error:)
      open = open_execution(record)
      return if open.nil? # no open attempt: nowhere to record

      open["finished_at"] = timestamp
      open["outcome"] = outcome
      open["error"] = deep_stringify(error)
    end

    # Materializes Task from the raw Hash (type normalization at the edge):
    # `status` comes back as a Symbol (domain enum, compared against
    # STATUSES); `command`/`mailbox_state`/`error` stay as Hashes with string keys
    # (they are data, not enums).
    def to_task(record)
      Task.new(
        id: record["id"],
        status: record["status"].to_sym,
        command: record["command"],
        session_id: record["session_id"],
        executions: record["executions"].map { |e| to_execution(e) },
        mailbox_state: record["mailbox_state"],
        created_at: record["created_at"],
        updated_at: record["updated_at"]
      )
    end

    def to_execution(hash)
      Execution.new(
        attempt: hash["attempt"],
        started_at: hash["started_at"],
        finished_at: hash["finished_at"],
        outcome: hash["outcome"],
        error: hash["error"]
      )
    end

    def timestamp
      Time.now.utc.iso8601
    end
  end
end

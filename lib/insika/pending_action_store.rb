# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # Domain store for PENDING approval ACTIONS ("state as a
  # record, not a flag"). A tool marked `approval` (Policy) creates a
  # PendingAction and the turn goes to :waiting; the operator resolves it via ApproveAction.
  # Durable (over an injected Insika::Store): survives a kill -9 — the operator
  # approves after the reboot, and Recovery rehydrates the task in :waiting.
  #
  # Normalizes symbol→string on WRITE (the backend only guarantees round-trip of JSON
  # types), like the other domain stores.
  class PendingActionStore
    include Coercion

    SCOPE = "pending_actions"
    KEY_PREFIX = "pending:"

    STATUSES = %i[pending approved rejected].freeze

    PendingAction = Data.define(:id, :task_id, :turn, :tool, :args,
                                :status, :requested_at, :resolved_by, :resolved_at)

    def initialize(store:)
      @store = store
    end

    # -> PendingAction (:pending). `args` is the Hash of the tool call's arguments.
    def create(task_id:, turn:, tool:, args: {}, id: SecureRandom.uuid)
      record = {
        "id" => id.to_s,
        "task_id" => task_id.to_s,
        "turn" => turn,
        "tool" => tool.to_s,
        "args" => deep_stringify(args),
        "status" => "pending",
        "requested_at" => timestamp,
        "resolved_by" => nil,
        "resolved_at" => nil
      }
      @store.set(SCOPE, key_for(id), record)
      to_pending(record)
    end

    # -> PendingAction | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_pending(record)
    end

    # -> [PendingAction] :pending for the task (recovery/UI). O(n) scan — single-node,
    # like TaskStore#running_or_interrupted.
    def open_for(task_id)
      id = task_id.to_s
      @store.list(SCOPE, KEY_PREFIX).filter_map do |key|
        record = @store.get(SCOPE, key)
        next if record.nil?

        pa = to_pending(record)
        pa if pa.status == :pending && pa.task_id == id
      end
    end

    # -> [PendingAction] every :pending across all tasks — the approvals inbox
    # (§12 G5, Studio). Single O(n) scan (vs. open_for per task = O(n·m)); the
    # UI resolves task context afterwards via TaskStore#find.
    def all_open
      @store.list(SCOPE, KEY_PREFIX).filter_map do |key|
        record = @store.get(SCOPE, key)
        next if record.nil?

        pa = to_pending(record)
        pa if pa.status == :pending
      end
    end

    # -> resolved PendingAction. Only resolves :pending: a double resolution
    # or an invalid decision -> ValidationError; absent -> NotFoundError.
    def resolve(id, decision:, operator: nil)
      target = decision.to_sym
      unless %i[approved rejected].include?(target)
        raise Insika::ValidationError, "invalid decision: #{decision} (approved|rejected)"
      end

      record = @store.get(SCOPE, key_for(id)) ||
               (raise Insika::NotFoundError, "pending action not found: #{id}")
      unless record["status"] == "pending"
        raise Insika::ValidationError, "pending action '#{id}' already resolved (#{record["status"]})"
      end

      record["status"] = target.to_s
      record["resolved_by"] = operator&.to_s
      record["resolved_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_pending(record)
    end

    private

    def key_for(id) = "#{KEY_PREFIX}#{id}"

    def to_pending(record)
      PendingAction.new(
        id: record["id"],
        task_id: record["task_id"],
        turn: record["turn"],
        tool: record["tool"],
        args: record["args"],
        status: record["status"].to_sym,
        requested_at: record["requested_at"],
        resolved_by: record["resolved_by"],
        resolved_at: record["resolved_at"]
      )
    end

    def timestamp = Time.now.utc.iso8601
  end
end

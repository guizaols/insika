# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # Durable record of an ASYNC delegation (RFC-0010 §5, item 21 Phase 2, hermes
  # "delegation durability"). The synchronous subagent (Phase 1) needs no
  # record — it lives and dies inside the parent's turn. The ASYNC subagent does:
  # the parent DISPATCHES and its turn ends; the child runs independently; when the
  # child finishes, its result is delivered to the parent as a NEW turn (never
  # spliced mid-turn — preserves role alternation + prompt cache). This record is
  # what survives a kill -9 so a completed child's result is never lost.
  #
  # Lifecycle (never backwards): dispatched -> completed -> delivered.
  #   dispatched  the child was spawned; result not captured yet.
  #   completed   the child is terminal; result/error captured durably.
  #   delivered   the result was handed to the parent session (claimed — the
  #               claim is what makes delivery AT-MOST-ONCE across crashes).
  #
  # Normalizes symbol->string on WRITE (the backend only round-trips JSON types),
  # like the other domain stores.
  class DelegationStore
    include Coercion

    SCOPE = "delegations"
    KEY_PREFIX = "delegation:"

    STATUSES = %i[dispatched completed delivered].freeze

    Delegation = Data.define(
      :id, :parent_task_id, :parent_session_id, :parent_agent,
      :child_agent, :child_task_id, :child_session_id, :depth,
      :status, :result, :error, :created_at, :updated_at
    )

    def initialize(store:)
      @store = store
    end

    # -> Delegation (:dispatched).
    def create(parent_task_id:, parent_session_id:, parent_agent:, child_agent:,
               child_task_id:, child_session_id:, depth:, id: SecureRandom.uuid)
      record = {
        "id" => id.to_s,
        "parent_task_id" => parent_task_id.to_s,
        "parent_session_id" => parent_session_id&.to_s,
        "parent_agent" => parent_agent.to_s,
        "child_agent" => child_agent.to_s,
        "child_task_id" => child_task_id.to_s,
        "child_session_id" => child_session_id.to_s,
        "depth" => depth,
        "status" => "dispatched",
        "result" => nil,
        "error" => nil,
        "created_at" => timestamp,
        "updated_at" => timestamp
      }
      @store.set(SCOPE, key_for(id), record)
      to_delegation(record)
    end

    # -> Delegation | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_delegation(record)
    end

    # -> Delegation | nil for a given child task (the terminal hook's lookup). O(n)
    # scan — single-node, like PendingActionStore#open_for.
    def find_by_child_task(child_task_id)
      id = child_task_id.to_s
      scan { |d| return d if d.child_task_id == id }
      nil
    end

    # -> [Delegation] that are NOT delivered yet (boot recovery). completed-but-
    # undelivered = a crash between capture and delivery; dispatched = the child
    # may or may not be terminal (the caller checks the child task).
    def undelivered
      scan.reject { |d| d.status == :delivered }
    end

    # dispatched -> completed, capturing the child's result/error. Idempotent: a
    # second call on an already-completed/delivered record is a no-op (returns the
    # current record) — the terminal hook and recovery can race.
    def mark_completed(id, result: nil, error: nil)
      record = fetch!(id)
      return to_delegation(record) unless record["status"] == "dispatched"

      record["status"] = "completed"
      record["result"] = result
      record["error"] = error
      touch(id, record)
    end

    # completed -> delivered, ATOMICALLY (the claim). Returns true only for the
    # caller that won the transition — that caller (and only it) spawns the delivery
    # turn, so delivery is at-most-once even if the hook and recovery both fire.
    # A record not in :completed (already delivered, or still dispatched) -> false.
    def claim_delivery(id)
      record = @store.get(SCOPE, key_for(id))
      return false unless record && record["status"] == "completed"

      record["status"] = "delivered"
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      true
    end

    private

    def scan
      return enum_for(:scan) unless block_given?

      @store.list(SCOPE, KEY_PREFIX).each do |key|
        record = @store.get(SCOPE, key)
        yield to_delegation(record) if record
      end
    end

    def fetch!(id)
      @store.get(SCOPE, key_for(id)) ||
        (raise Insika::NotFoundError, "delegation not found: #{id}")
    end

    def touch(id, record)
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_delegation(record)
    end

    def key_for(id) = "#{KEY_PREFIX}#{id}"

    def to_delegation(record)
      Delegation.new(
        id: record["id"], parent_task_id: record["parent_task_id"],
        parent_session_id: record["parent_session_id"], parent_agent: record["parent_agent"],
        child_agent: record["child_agent"], child_task_id: record["child_task_id"],
        child_session_id: record["child_session_id"], depth: record["depth"],
        status: record["status"].to_sym, result: record["result"], error: record["error"],
        created_at: record["created_at"], updated_at: record["updated_at"]
      )
    end

    def timestamp = Time.now.utc.iso8601
  end
end

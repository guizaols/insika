# frozen_string_literal: true

require "time"

module Insika
  # Domain store for checkpoints. A per-turn snapshot written
  # in an ALL-OR-NOTHING transaction (invariant: a checkpoint is either fully
  # valid or does not exist), a record of non-idempotent side effects in a spill
  # key during the turn, and `prune` to bound growth.
  #
  # Two key families in the "checkpoints" scope:
  #   "checkpoint:<task_id>:turn:<n>"  -> Checkpoint JSON
  #   "sideeffects:<task_id>:turn:<n>" -> ["tool_call_id", ...] (spill key)
  #
  # The spill key exists because the turn's checkpoint does not exist yet when
  # the tool calls run (it is only saved at stage 8): it is written BEFORE the
  # tool result goes back to the model, and the following `save` consolidates it
  # into `completed_side_effects` and deletes it in the SAME transaction.
  class CheckpointStore
    include Coercion

    SCOPE = "checkpoints"

    def initialize(store:)
      @store = store
    end

    # -> Checkpoint (with the consolidated side-effect list). ALWAYS in a
    # transaction. Order: validate monotonicity -> consolidate the previous
    # turn's spill key -> write the checkpoint -> delete the absorbed spill key.
    # Any exception in the middle -> full rollback (neither a partial checkpoint
    # nor a lost spill key).
    def save(checkpoint)
      @store.transaction do
        current = latest(checkpoint.task_id)
        if current && current.turn >= checkpoint.turn
          raise ArgumentError,
                "checkpoint with non-monotonic turn: #{checkpoint.turn} <= #{current.turn}"
        end

        # Stage 8 of turn n saves turn n+1's checkpoint:
        # the spill key to absorb is that of the turn that just executed (n).
        spill_key = sideeffects_key(checkpoint.task_id, checkpoint.turn - 1)
        spilled = @store.get(SCOPE, spill_key) || []
        consolidated = Array(checkpoint.completed_side_effects).map(&:to_s) | spilled

        record = deep_stringify(checkpoint.to_h)
        record["completed_side_effects"] = consolidated
        record["created_at"] ||= timestamp
        @store.set(SCOPE, checkpoint_key(checkpoint.task_id, checkpoint.turn), record)
        @store.delete(SCOPE, spill_key)

        to_checkpoint(record)
      end
    end

    # -> Checkpoint | nil (highest turn). NUMERIC ordering: `list` sorts
    # lexicographically and "turn:9" > "turn:10" — parse n as an Integer.
    def latest(task_id)
      turns = checkpoint_turns(task_id)
      return nil if turns.empty?

      find(task_id, turn: turns.max)
    end

    # -> Checkpoint | nil
    def find(task_id, turn:)
      record = @store.get(SCOPE, checkpoint_key(task_id, turn))
      record && to_checkpoint(record)
    end

    # -> nil; idempotent (recording twice = one entry). In a transaction
    # (written before the tool goes back to the model).
    def record_side_effect(task_id, turn:, tool_call_id:)
      @store.transaction do
        key = sideeffects_key(task_id, turn)
        ids = @store.get(SCOPE, key) || []
        id = tool_call_id.to_s
        @store.set(SCOPE, key, ids + [id]) unless ids.include?(id)
      end
      nil
    end

    # -> [tool_call_id] = spill key ∪ checkpoint of the same turn.
    # Covers both places where an id may live during the cycle; since
    # tool_call_id is globally unique, the union never causes an improper skip.
    def side_effects(task_id, turn:)
      spilled = @store.get(SCOPE, sideeffects_key(task_id, turn)) || []
      from_checkpoint = find(task_id, turn: turn)&.completed_side_effects || []
      spilled | from_checkpoint
    end

    # -> void. Keeps the `keep` checkpoints with the highest turn (numeric); deletes the
    # rest. Also clears spill keys of turns strictly smaller than the smallest
    # kept turn (unreachable garbage after consolidation). In a transaction
    # so it never leaves a partial prune. No-op if there are <= keep checkpoints.
    def prune(task_id, keep: 1)
      @store.transaction do
        turns = checkpoint_turns(task_id).sort
        next if turns.size <= keep

        kept = turns.last(keep)
        smallest_kept = kept.first
        (turns - kept).each { |n| @store.delete(SCOPE, checkpoint_key(task_id, n)) }
        sideeffect_turns(task_id).each do |n|
          @store.delete(SCOPE, sideeffects_key(task_id, n)) if n < smallest_kept
        end
      end
      nil
    end

    # Deletes EVERY checkpoint + side-effect record of the task (WS8 retention:
    # a purged task's durability trail goes with it — no orphaned keys).
    # -> count of records removed.
    def purge(task_id)
      removed = 0
      checkpoint_turns(task_id).each do |n|
        @store.delete(SCOPE, checkpoint_key(task_id, n))
        removed += 1
      end
      sideeffect_turns(task_id).each do |n|
        @store.delete(SCOPE, sideeffects_key(task_id, n))
        removed += 1
      end
      removed
    end

    private

    def checkpoint_key(task_id, turn)
      "checkpoint:#{task_id}:turn:#{turn}"
    end

    def sideeffects_key(task_id, turn)
      "sideeffects:#{task_id}:turn:#{turn}"
    end

    def checkpoint_turns(task_id)
      @store.list(SCOPE, "checkpoint:#{task_id}:turn:").map { |k| turn_of(k) }
    end

    def sideeffect_turns(task_id)
      @store.list(SCOPE, "sideeffects:#{task_id}:turn:").map { |k| turn_of(k) }
    end

    # n is the last segment of the key "...:turn:<n>"; parse it as an Integer.
    def turn_of(key)
      key.split(":").last.to_i
    end

    # Materializes at the edge: `turn` as an Integer; the other fields as they come from the
    # backend (string keys in `messages`).
    def to_checkpoint(record)
      Checkpoint.new(
        task_id: record["task_id"],
        turn: record["turn"].to_i,
        session_id: record["session_id"],
        agent_id: record["agent_id"],
        messages: record["messages"],
        completed_side_effects: record["completed_side_effects"],
        created_at: record["created_at"]
      )
    end

    def timestamp
      Time.now.utc.iso8601
    end
  end
end

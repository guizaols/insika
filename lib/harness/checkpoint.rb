# frozen_string_literal: true

module Harness
  # Per-turn snapshot. The checkpoint of
  # turn n holds the state AT THE START of turn n — resuming = re-executing the
  # whole turn n. `messages` is the MATERIALIZED transcript (not a cursor): the
  # checkpoint is self-contained and resumption does not depend on the Session Store.
  #
  # `completed_side_effects`: ids of non-idempotent tool calls already completed
  # within the turn (resumption answers them with "already_executed").
  Checkpoint = Data.define(:task_id, :turn, :session_id, :agent_id,
                           :messages, :completed_side_effects, :created_at)
end

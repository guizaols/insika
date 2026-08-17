# frozen_string_literal: true

# The Executor surface `SendMessage` drives: the spawn, plus's three doors for a
# session that is already busy.
#
# Every door DECLINES by default, which is `followup` — what every agent gets unless it
# asked for something else. A spec that exercises one door passes just that one:
#
#   FakeTurnExecutor.new(collect: "t-open")   # any fragment merges into t-open
#   FakeTurnExecutor.new(steer: "t-running")  # any message joins the running turn
#
# Shared on purpose. Each door used to be added to four or five bespoke doubles, so
# opening the third one failed five specs with a NoMethodError that said nothing about
# the feature. One place to wire the next one.
class FakeTurnExecutor
  # [[task, profile], …] — the turns that were actually spawned.
  attr_reader :spawned
  # [timing, …] — the RFC-0027 C5 channel clock threaded alongside each spawn
  # (nil for a non-channel turn). Kept apart so the shared `spawned` shape stays.
  attr_reader :spawned_timing
  # [[door, session_id, text], …] — the JOINING doors (collect/steer) that were asked, in
  # order. A spec asserts this is EMPTY to prove a surface never even opened one.
  attr_reader :asked
  # [[session_id, replaced_by], …] — interrupt is not a joining door: it takes no verdict
  # and is asked on every message, so it is recorded apart from the two that join.
  attr_reader :interrupts

  def initialize(collect: nil, steer: nil, interrupt: nil)
    @spawned = []
    @spawned_timing = []
    @asked = []
    @interrupts = []
    @collect = collect
    @steer = steer
    @interrupt = interrupt
  end

  def spawn_in_session(task, profile:, resume_from: nil, timing: nil)
    @spawned << [task, profile]
    @spawned_timing << timing
  end

  def collect_into_pending(session_id, text, profile:)
    @asked << [:collect, session_id, text]
    @collect
  end

  def steer_into_running(session_id, text, profile:)
    @asked << [:steer, session_id, text]
    @steer
  end

  def interrupt_running(session_id, profile:, replaced_by: nil)
    @interrupts << [session_id, replaced_by]
    @interrupt
  end
end

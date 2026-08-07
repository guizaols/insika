# frozen_string_literal: true

require "async"
require "async/queue"

module Insika
  # Sessions as Actors: one fiber per session with a FIFO queue
  # of turns, executed ONE AT A TIME. Restores the "one owner at a time"
  # invariant of the transcript that two concurrent `send_message` calls on the
  # same `session_id` would break (read-modify-write on the Session Store). Turns
  # from distinct sessions stay concurrent; one-shot/history (no session_id) do
  # not go through here.
  #
  # Lives in the SUPERVISED scope: the loop is a child of the supervisor, not of
  # the request — it outlives the connection. The turn itself (spawned by the
  # Executor) is also born on the supervisor; the SessionActor only AWAITS it to
  # serialize.
  #
  # RFC-0015: it is also where an inbound message for a BUSY session is routed.
  # That decision belongs here and nowhere else — this is already the object that
  # owns "one turn at a time for this session". Putting it in the HTTP handler
  # would duplicate the invariant; putting it in the Executor would mix turn
  # execution with queue policy.
  class SessionActor
    def initialize(session_id:, executor:, parent: Async::Task.current)
      @session_id = session_id
      @executor = executor
      @queue = Async::Queue.new
      @running = false
      # The turn currently sitting at the door: created and :queued, but not yet
      # released to run. `collect` merges into THIS one. nil whenever there is
      # nothing mergeable — which is the common case and the safe default.
      @pending = nil
      @loop = parent.async { |t| t.annotate("session:#{session_id}"); run_loop }
    end

    # Enqueues a turn (FIFO). Non-blocking: the handler responds with an
    # immediate {task_id:} even if the turn stays :queued behind another. -> task.id.
    #
    # `policy` (a QueuePolicy) opens the debounce window for this turn; nil or a
    # policy without a window behaves exactly as before — dequeued and run at once.
    def enqueue(task, profile:, resume_from: nil, policy: nil)
      @queue.enqueue([task, profile, resume_from, policy])
      task.id
    end

    # RFC-0015 §5.3 — merge a fragment into the turn waiting at the door.
    # -> the task id it joined, or nil when there is nothing to merge into (no
    # pending turn, the window has closed, or the turn already started). nil is
    # the caller's signal to create a task of its own.
    #
    # Runs on the REQUEST's fiber, not the loop's; both are on the same reactor
    # and neither yields between the check and the write below, so the "is it
    # still mergeable" test and the append cannot interleave.
    def collect(text)
      pending = @pending
      return nil if pending.nil?

      @executor.task_store.append_message(pending[:task_id], text)
      pending[:count] += 1
      pending[:version] += 1 # tells a sleeping debounce window that more arrived
      pending[:task_id]
    rescue ArgumentError
      # The turn left :queued between the read of @pending and the append (it was
      # released while we were deciding). Not an error: the caller falls back to
      # creating its own task, which is exactly `followup`.
      nil
    end

    def running? = @running
    def depth = @queue.size

    # Is there a turn at the door that `collect` could still merge into?
    def collecting? = !@pending.nil?

    # Is the loop still alive? (the Executor revalidates before reusing from the
    # cache — a dead loop would black-hole queued turns).
    def alive? = !!@loop&.running?

    # Shuts down the loop (server shutdown / tests — the loop blocks forever on
    # dequeue when idle).
    def stop = @loop&.stop

    private

    def run_loop
      loop do
        task, profile, resume_from, policy = @queue.dequeue # blocks when empty
        task = hold_at_the_door(task, policy)
        @running = true
        begin
          @executor.run_serial(task, profile: profile, resume_from: resume_from)
        rescue StandardError
          # run_serial already maps turn errors; this rescue is defense: an
          # unexpected error must NEVER bring down the session loop (Async::Stop <
          # Exception is not captured -> #stop ends the loop normally).
          nil
        ensure
          @running = false
        end
      end
    end

    # RFC-0015 §5.3 — the debounce window. Sleeps on the LOOP's fiber, never on the
    # request's, so the POST is acked immediately and the platform does not retry.
    # Returns the task to run (re-read from the store when fragments merged into it,
    # since the in-memory Task is a frozen snapshot of an older message).
    def hold_at_the_door(task, policy)
      return task unless policy&.debounce?

      @pending = { task_id: task.id, count: 1, version: 0 }
      begin
        wait_for_quiet(policy)
        merged = @pending[:count]
      ensure
        # The window is closed BEFORE the turn runs, under every exit path: a
        # `collect` that slipped in here would append to a task about to be read.
        @pending = nil
      end

      return task if merged == 1

      @executor.emit_coalesced(task, merged: merged)
      @executor.task_store.find(task.id) || task
    end

    # Sleeps in `debounce_ms` slices, restarting whenever a fragment arrives
    # (`version` moved), until either a slice passes in silence or the total
    # deferral reaches `debounce_max_ms` — the ceiling that stops a customer who
    # keeps typing from postponing their own answer forever.
    def wait_for_quiet(policy)
      quiet = policy.debounce_ms / 1000.0
      deadline = monotonic + (policy.debounce_max_ms / 1000.0)

      loop do
        mark = @pending[:version]
        Async::Task.current.sleep(quiet)
        break if @pending[:version] == mark # a full slice of silence
        break if monotonic >= deadline
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

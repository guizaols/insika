# frozen_string_literal: true

require "async"
require "async/queue"
require "time" # Time#iso8601 for the arrival record on :turn_coalesced

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
  # it is also where an inbound message for a BUSY session is routed.
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
      # The turns sitting at the door: created and :queued, but not yet released to
      # run — whether waiting out a debounce window or simply queued behind the turn
      # in flight. `collect` merges into the LAST one (the turn that has not
      # answered yet; appending to an older one would put a newer fragment in an
      # older message). Keyed by task so a turn released from the FIFO still finds
      # its OWN count — with a single slot, a second turn enqueued behind the first
      # would take the first's fragments with it. Empty is the common case and the
      # safe default: a policy that does not merge never opens one.
      @doors = {}
      @loop = parent.async { |t| t.annotate("session:#{session_id}"); run_loop }
    end

    # Enqueues a turn (FIFO). Non-blocking: the handler responds with an
    # immediate {task_id:} even if the turn stays :queued behind another. -> task.id.
    #
    # `policy` (a QueuePolicy) decides the door: a merging mode (`collect`/`steer`)
    # opens it here, and a `debounce_ms` on top of that also holds the turn once it
    # reaches the front. A nil policy or `followup` behaves exactly as before —
    # nothing to merge into, dequeued and run at once.
    #
    # `timing`  is the channel clock a channel turn allocated at 202
    # acceptance and already stamped `:inbound`; it rides the queue so the debounce
    # window and the FIFO wait land INSIDE first_balloon_ms.
    def enqueue(task, profile:, resume_from: nil, policy: nil, timing: nil)
      # The door opens HERE, not when the turn is dequeued. "Created and not yet
      # started" lasts as long as the turn IN FRONT takes, and that whole wait is
      # mergeable: the turn has not spoken, so a fragment appended to it costs
      # nothing and saves an answer. Opening the door only for a debounce window
      # (where it used to live) left every message that arrived while a turn sat in
      # the FIFO with nothing to join — it became a turn of its own behind two
      # others, and a `stream=false` caller then waited for BOTH to run before it
      # heard anything. A window is now what EXTENDS the door, never what creates it.
      @doors[task.id] = open_door(task) if policy&.collect?
      @queue.enqueue([task, profile, resume_from, policy, timing])
      task.id
    end

    # merge a fragment into the turn waiting at the door.
    # -> the task id it joined, or nil when there is nothing to merge into (no
    # pending turn, the window has closed, or the turn already started). nil is
    # the caller's signal to create a task of its own.
    #
    # Runs on the REQUEST's fiber, not the loop's; both are on the same reactor
    # and neither yields between the check and the write below, so the "is it
    # still mergeable" test and the append cannot interleave.
    def collect(text)
      pending = @doors.values.last
      return nil if pending.nil?

      @executor.task_store.append_message(pending[:task_id], text)
      pending[:count] += 1
      # A merged fragment leaves NO task of its own (see #hold_at_the_door), so this
      # is the only record that it arrived as a separate message. Kept as arrival
      # times — never the text — and shipped on :turn_coalesced, so "the customer
      # says they sent the order number" is answerable without the store carrying an
      # orphan task per fragment.
      pending[:arrivals] << Time.now.utc.iso8601
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

    # The turn this session is running RIGHT NOW, or nil when idle or still at the
    # door. `steer` needs the Task itself and not just its id: whether a turn can
    # absorb a message at all depends on what kind of turn it is (a workflow has no
    # chat), and reading that off the object avoids a store round-trip on the
    # request's path.
    attr_reader :current_task

    # Is there a turn at the door that `collect` could still merge into? True from
    # the moment a merging policy enqueues one until it starts running.
    def collecting? = !@doors.empty?

    # Is the loop still alive? (the Executor revalidates before reusing from the
    # cache — a dead loop would black-hole queued turns).
    def alive? = !!@loop&.running?

    # Shuts down the loop (server shutdown / tests — the loop blocks forever on
    # dequeue when idle).
    def stop = @loop&.stop

    private

    def run_loop
      loop do
        task, profile, resume_from, policy, timing = @queue.dequeue # blocks when empty
        task = hold_at_the_door(task, policy)
        @running = true
        @current_task = task
        begin
          @executor.run_serial(task, profile: profile, resume_from: resume_from, timing: timing)
        rescue StandardError
          # run_serial already maps turn errors; this rescue is defense: an
          # unexpected error must NEVER bring down the session loop (Async::Stop <
          # Exception is not captured -> #stop ends the loop normally).
          nil
        ensure
          @running = false
          @current_task = nil
        end
      end
    end

    # Closes the turn's door and reports what it caught. The debounce
    # window (when the policy has one) is the EXTRA wait held here, on the LOOP's
    # fiber and never on the request's, so the POST is acked immediately and the
    # platform does not retry. Returns the task to run — re-read from the store when
    # fragments merged into it, since the in-memory Task is a frozen snapshot of an
    # older message.
    def hold_at_the_door(task, policy)
      pending = @doors[task.id]
      return task if pending.nil?

      begin
        wait_for_quiet(policy, pending) if policy&.debounce?
        merged = pending[:count]
      ensure
        # The door closes BEFORE the turn runs, under every exit path: a `collect`
        # that slipped in here would append to a task about to be read.
        @doors.delete(task.id)
      end

      return task if merged == 1

      @executor.emit_coalesced(task, merged: merged, arrivals: pending[:arrivals])
      @executor.task_store.find(task.id) || task
    end

    def open_door(task)
      { task_id: task.id, count: 1, version: 0, arrivals: [Time.now.utc.iso8601] }
    end

    # Sleeps in `debounce_ms` slices, restarting whenever a fragment arrives
    # (`version` moved), until either a slice passes in silence or the total
    # deferral reaches `debounce_max_ms` — the ceiling that stops a customer who
    # keeps typing from postponing their own answer forever.
    def wait_for_quiet(policy, pending)
      quiet = policy.debounce_ms / 1000.0
      deadline = monotonic + (policy.debounce_max_ms / 1000.0)

      loop do
        mark = pending[:version]
        Async::Task.current.sleep(quiet)
        break if pending[:version] == mark # a full slice of silence
        break if monotonic >= deadline
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

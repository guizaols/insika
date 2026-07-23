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
  class SessionActor
    def initialize(session_id:, executor:, parent: Async::Task.current)
      @session_id = session_id
      @executor = executor
      @queue = Async::Queue.new
      @running = false
      @loop = parent.async { |t| t.annotate("session:#{session_id}"); run_loop }
    end

    # Enqueues a turn (FIFO). Non-blocking: the handler responds with an
    # immediate {task_id:} even if the turn stays :queued behind another. -> task.id.
    def enqueue(task, profile:, resume_from: nil)
      @queue.enqueue([task, profile, resume_from])
      task.id
    end

    def running? = @running
    def depth = @queue.size

    # Is the loop still alive? (the Executor revalidates before reusing from the
    # cache — a dead loop would black-hole queued turns).
    def alive? = !!@loop&.running?

    # Shuts down the loop (server shutdown / tests — the loop blocks forever on
    # dequeue when idle).
    def stop = @loop&.stop

    private

    def run_loop
      loop do
        task, profile, resume_from = @queue.dequeue # blocks when empty
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
  end
end

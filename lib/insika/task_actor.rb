# frozen_string_literal: true

require "async"
require "async/queue"

module Insika
  # Actor model: one Async fiber per Task + a mailbox. The message enum is
  # `cancel`/`user_message`/`approval`/`pause`/`resume`/`timeout`/`heartbeat`, with
  # `await` as the cooperative SUSPENSION primitive. Cancellation/suspension only
  # at stage boundaries — never in the middle of an operation.
  class TaskActor
    # `user_message` is posted by `Executor#steer_into_running` and
    # consumed by `SteerInjector` at a tool-batch boundary. `pause`/`resume` (operator),
    # `approval` (human-in-the-loop), `timeout`/`heartbeat`
    # (watchdog/liveness, observation).
    MESSAGES = %i[cancel user_message approval pause resume timeout heartbeat].freeze

    attr_reader :task_id, :pending_user_messages, :heartbeats
    # How many messages this run was ASKED to absorb, ever — including the ones
    # already injected and cleared. It is what bounds steering (`steer_max_messages`),
    # so it counts posts and never decreases.
    attr_reader :user_messages_posted

    def initialize(task_id:, parent: Async::Task.current)
      @task_id = task_id
      @parent = parent
      @mailbox = Async::Queue.new
      @pending_user_messages = []
      @pause_requested = false
      @heartbeats = 0
      @user_messages_posted = 0
    end

    # Non-blocking. A message outside the enum is a caller bug.
    def post(message, data = nil)
      raise ArgumentError, "unknown message: #{message}" unless MESSAGES.include?(message)

      @user_messages_posted += 1 if message == :user_message
      @mailbox.enqueue([message, data])
      nil
    end

    # Runs the block on an Async fiber CHILD of the parent. Returns the Task.
    def run(&turn_block)
      @async_task = @parent.async { turn_block.call(self) }
    end

    # Drains the mailbox WITHOUT blocking (boundaries). `:cancel` raises (the top
    # of the fiber maps to :cancelled). `:pause` arms the suspension (the Executor
    # checks `pause_requested?`). Resolutions (`:resume`/`:approval`/`:timeout`)
    # that arrive here WITH no pending suspension are DISCARDED (idempotent,
    # no-op).
    def drain!
      until @mailbox.empty?
        route_boundary(*@mailbox.dequeue)
      end
      nil
    end

    # Did the operator request a pause? (consumed by the Executor; `await` clears
    # the flag).
    def pause_requested? = @pause_requested

    # takes the steered messages and clears the buffer, WITHOUT
    # observing anything else in the mailbox: whatever is not a `:user_message` is put
    # back, in the order it arrived.
    #
    # Why not `drain!`: this runs INSIDE RubyLLM's tool loop (a `after_message`
    # callback), and `drain!` raises on `:cancel`. Cancellation is only ever observed
    # at the Executor's own stage boundaries — that is what keeps a tool batch one
    # unit of work (and for the same rule under `turn_timeout`).
    # Injecting a message must not quietly become a new place a turn can die.
    def take_user_messages!
      @mailbox.size.times do
        message, data = @mailbox.dequeue
        message == :user_message ? @pending_user_messages << data : @mailbox.enqueue([message, data])
      end
      taken = @pending_user_messages.dup
      @pending_user_messages.clear
      taken
    end

    # BLOCKS the turn's fiber until a RESOLUTION (yields the reactor — no spin).
    # Used by the Executor in :paused (waits for :resume) and by the ToolEnvelope
    # in :waiting (waits for :approval). Returns [:resume, nil] or [:approval,
    # data]. `:cancel` -> CancelledError; `:timeout` -> TimeoutError. A legitimate
    # resolution only arrives WITH the fiber already blocked here (the operator
    # only resumes/approves what is suspended), so it is consumed by this
    # `dequeue` — there is no race requiring a buffer. Non-resolution messages
    # received during the wait are ABSORBED without changing the suspension state
    # (a redundant :pause does not re-arm the pause).
    def await(reason:)
      @pause_requested = false # the pause/wait is being handled now
      loop do
        message, data = @mailbox.dequeue
        case message
        when :cancel        then raise CancelledError, "task #{@task_id} cancelled"
        when :timeout       then raise Insika::TimeoutError.new("wait (#{reason}) exceeded", stage: data || reason)
        when :resume, :approval then return [message, data]
        when :heartbeat     then @heartbeats += 1
        when :user_message  then @pending_user_messages << data
        # :pause during the wait: already suspended, ignore (does not re-arm pause_requested)
        end
      end
    end

    # specs/boot await the fiber's completion.
    def wait = @async_task&.wait

    private

    # Routing of boundary messages (non-blocking). Orphan resolutions
    # (`:resume`/`:approval`/`:timeout` with no pending suspension) are DISCARDED —
    # NEVER buffered: a stored resolution would wrongly resolve a FUTURE `await`
    # (auto-resume/auto-approve/auto-timeout of a suspension the operator did not
    # resolve). Legitimate resolutions arrive with the fiber already in `await`
    # (consumed there), so discarding here is safe and idempotent.
    def route_boundary(message, data)
      case message
      when :cancel then raise CancelledError, "task #{@task_id} cancelled"
      when :pause then @pause_requested = true
      when :user_message then @pending_user_messages << data
      when :heartbeat then @heartbeats += 1
      when :resume, :approval, :timeout then nil # orphan: discard (see comment)
      end
    end
  end
end

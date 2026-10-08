# frozen_string_literal: true

require "async"
require "async/queue"

module Insika
  # In-process pub/sub. The stream is concurrent with the
  # turn: a slow observer NEVER delays execution — each subscriber
  # has its own queue and `emit` only enqueues. No mutex: one reactor, cooperative
  # fibers — a plain Array is enough.
  class EventStream
    EMPTY = [].freeze
    # One subscription = one queue. The consumer blocks on `each` (its own fiber),
    # never the emitter.
    class Subscription
      CLOSED = Object.new # internal end-of-stream sentinel
      private_constant :CLOSED

      # Cap on events queued per subscriber. A slow consumer
      # piles up in its OWN queue; on overflow, the subscription closes with a
      # local :error event — the turn never waits on transport.
      MAX_QUEUED = 1000

      attr_reader :session_id

      def initialize(task_id: nil, session_id: nil, tenant: nil, types: nil, on_close: nil)
        @task_id = task_id
        @session_id = session_id
        @tenant = tenant
        @types = types
        @on_close = on_close
        @queue = Async::Queue.new
      end

      # Binds the subscription to a task_id AFTER creation: the
      # transport subscribes before the dispatch — when the task_id does not yet
      # exist — and binds it as soon as the handler returns. This keeps the
      # per-task cap honest (only events for THIS task enter the queue) and makes
      # the overflow :error carry the correct task_id. Returns self to chain.
      def bind(task_id:)
        @task_id = task_id
        self
      end

      # Meta filter: nil = matches any value. Events with no task_id in
      # meta (e.g. :session_created) reach only subscribers with no task filter.
      #
      # A TENANT-scoped subscription is FAIL-CLOSED on the meta's tenant (WS1):
      # an event that does not carry the tenant (control events, ignored turns)
      # matches NO tenant subscription. The tenant only ever sees its own.
      #
      # `types:` (nil = any) keeps a subscriber's queue to the events it answers
      # — an alert consumer must not sit behind a full-traffic stream's 1000-cap
      # (WS6), and a filtered queue is the cheapest way to keep it there.
      def matches?(event)
        meta = event.meta || {}
        owned = @tenant.nil? || meta[:tenant] == @tenant

        owned &&
          (@types.nil? || @types.include?(event.type)) &&
          (@task_id.nil? || meta[:task_id] == @task_id) &&
          (@session_id.nil? || meta[:session_id] == @session_id)
      end

      # Enqueues without EVER blocking. The real queue depth is `@queue.size`
      # (not a separate counter — avoids drift). On reaching the cap, it enqueues
      # a local :error and closes; pushes after close are ignored (`@closed`).
      def push(event)
        return if @closed

        if @queue.size >= MAX_QUEUED
          @queue.enqueue(Insika::Event.new(
                           type: :error,
                           data: { message: "subscription overflow" },
                           meta: { task_id: @task_id, session_id: @session_id }
                         ))
          close
          return
        end

        @queue.enqueue(event)
      end

      # Blocks the CONSUMER's fiber until #close.
      def each
        while (event = @queue.dequeue) != CLOSED
          yield event
        end
      end

      # Drains whatever is ALREADY queued without ever blocking. Safe in a
      # cooperative reactor: between the `empty?` check and the `dequeue` no other
      # fiber runs, so a non-empty dequeue never waits. The eval transports use it
      # to collect the events a turn already emitted, AFTER the turn returned.
      def drain_nonblocking
        drained = []
        drained << @queue.dequeue until @queue.empty?
        drained
      end

      # Idempotent: a second CLOSED is harmless (the `each` stops at the first).
      # `@on_close` fires only once (avoids removing the subscription twice).
      def close
        return if @closed

        @closed = true
        @queue.enqueue(CLOSED)
        @on_close&.call(self)
      end
    end

    # Subscriptions by the session they filter on (nil = any session). A session
    # filter never changes after subscribe, so an event only needs the any-session
    # list plus its own session's: emit does not walk every open conversation.
    def initialize
      @subscriptions = {}
      @running = {} # session_id -> { task_id -> [Event] } of the turns still running
    end

    # NEVER raises: an observer's exception is isolated — a
    # broken observer does not bring down the turn. Synchronous and cheap.
    #
    # Iterates over a SNAPSHOT (a new array): a subscription's cap may close it
    # DURING the push (overflow -> close -> on_close removes from the array);
    # mutating the array in the middle of a plain Array#each would skip the next
    # subscriber.
    def emit(event)
      session_id = event.meta&.[](:session_id)
      candidates = @subscriptions.fetch(nil, EMPTY) + (session_id.nil? ? EMPTY : @subscriptions.fetch(session_id, EMPTY))
      remember(event, session_id)
      candidates.each do |sub|
        sub.push(event) if sub.matches?(event)
      rescue StandardError
        # a broken observer does not bring down the turn; nothing to propagate
      end
      nil
    end

    # nil/nil = all events. Returns the Subscription (the caller iterates with
    # `#each` on its own fiber). `tenant:` scopes the stream to one tenant's
    # events (WS1) — fail-closed, see Subscription#matches?. `types:` (nil =
    # any) filters by event type so a subscriber's queue only ever holds what
    # its consumer answers (WS6). `replay: true` first hands over what the
    # session's running turns already emitted: the transcript is only saved when
    # a turn ends, so a viewer who arrives mid-turn would otherwise miss it.
    def subscribe(task_id: nil, session_id: nil, tenant: nil, types: nil, replay: false)
      sub = Subscription.new(task_id: task_id, session_id: session_id, tenant: tenant,
                             types: types,
                             on_close: ->(s) { unsubscribe(s) })
      running_events(session_id).each { |event| sub.push(event) if sub.matches?(event) } if replay && session_id
      (@subscriptions[session_id] ||= []) << sub
      sub
    end

    private

    TERMINAL = %i[task_completed task_failed task_cancelled].freeze
    DELTAS = %i[intermediate thinking].freeze
    # Sessions whose running turn is kept. A turn that never reaches a terminal
    # (a crash) would stay forever; past this, the oldest is dropped.
    # ponytail: count cap, not a TTL — add one if stuck turns pile up.
    MAX_RUNNING = 200

    # Keeps the running turn of each session; consecutive deltas are merged into
    # one event (carrying the newest meta/seq) so a long turn stays a short list.
    def remember(event, session_id)
      task_id = event.meta&.[](:task_id)
      return if session_id.nil? || task_id.nil?

      if TERMINAL.include?(event.type)
        turns = @running[session_id] or return
        turns.delete(task_id)
        @running.delete(session_id) if turns.empty?
        return
      end

      events = ((@running[session_id] ||= {})[task_id] ||= [])
      last = events.last
      if last && DELTAS.include?(event.type) && last.type == event.type
        events[-1] = event.with(data: last.data.merge(delta: last.data[:delta].to_s + event.data[:delta].to_s))
      else
        events << event
      end
      @running.delete(@running.keys.first) if @running.size > MAX_RUNNING
    end

    def running_events(session_id)
      @running.fetch(session_id, {}).values.flatten
    end


    def unsubscribe(sub)
      list = @subscriptions[sub.session_id] or return
      list.delete(sub)
      @subscriptions.delete(sub.session_id) if list.empty?
    end
  end
end

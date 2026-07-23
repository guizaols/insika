# frozen_string_literal: true

require "json"
require "timeout"
require "async"
require "async/queue"

module Insika
  module Server
    # SSE response body (evolves `SSEStream`). `SSEStream`
    # received a producer block (the Runner wrote into it); `SSEBody` DRAINS a
    # `Subscription` from the EventStream: each subscriber has its
    # own queue; `#each` blocks the CONSUMER's fiber until the subscription
    # closes. The wire is EXACTLY `Event#to_h`.
    class SSEBody
      PING = ": ping\n\n" # SSE comment — doesn't pollute the consumer

      # serialize: maps an Event -> String (SSE frame) OR nil (discarded
      # event, no frame). Default = the canonical wire `data: <Event#to_h>`.
      # The /v1/responses adapter injects a serializer that produces OpenAI
      # Responses events (and skips those with no counterpart).
      DEFAULT_SERIALIZE = ->(event) { "data: #{JSON.generate(event.to_h)}\n\n" }

      # subscription: any object with #each (yields Events) and #close.
      # heartbeat: seconds of silence before emitting a ping (15s
      # clears 60s ALB/nginx idle timeouts with room to spare).
      def initialize(subscription:, heartbeat: 15, serialize: nil)
        @subscription = subscription
        @heartbeat = heartbeat
        @serialize = serialize || DEFAULT_SERIALIZE
      end

      # Rack 3 STREAMING BODY (`#call(stream)`), NOT `#each`. Under
      # protocol-rack/protocol-http1 (the stack of Async::HTTP::Server AND Falcon),
      # a body that responds to `#each` is routed to Body::Enumerable, whose
      # `read` runs the `#each` in a PLAIN Enumerator Fiber (not an Async::Task) —
      # there `Async::Task.current` raises "No async task available", the loop died
      # swallowed in the rescue and the body came out EMPTY. By exposing `#call` (and NOT `#each`),
      # the body is routed to Body::Streaming, which schedules the block via
      # Fiber.schedule under the reactor's scheduler — so the subscription drains and the
      # frames actually reach the socket (incrementally).
      #
      # The `stream` (Protocol::HTTP::Body::Stream) responds to #write/#close. Drains the
      # subscription DIRECTLY (no Async::Task.current): when this fiber blocks
      # waiting for the next event, the scheduler runs the writer, which pushes the
      # already-written frame to the socket. Heartbeat via Timeout.timeout (scheduler hook),
      # which works in the scheduled fiber — keeps the connection alive while idle (L4).
      def call(stream)
        drain(stream)
      rescue StandardError
        # Client disconnected: `stream.write` raises when the socket closes.
        # No exception escapes; the turn's task is NEVER cancelled here — the
        # execution belongs to the runtime, not the connection (reconnect at /v1/events).
        nil
      ensure
        @subscription.close
        stream.close
      end

      private

      def drain(stream)
        internal = Async::Queue.new
        closed = Object.new # end-of-subscription sentinel

        # Child fiber (scheduled on the reactor's scheduler): drains the subscription
        # into an internal queue and, on close, pushes the sentinel. Isolates the
        # subscription's blocking from the heartbeat loop. Ends on its own when
        # `@subscription.close` (in #call's ensure) makes the `each` finish — no
        # need to kill the fiber by hand.
        Fiber.schedule do
          @subscription.each { |event| internal.enqueue(event) }
        ensure
          internal.enqueue(closed)
        end

        loop do
          event =
            begin
              Timeout.timeout(@heartbeat) { internal.dequeue }
            rescue Timeout::Error
              :heartbeat # no event within `heartbeat`s -> ping
            end

          if event.equal?(:heartbeat)
            stream.write(PING)
          elsif event.equal?(closed)
            break
          elsif (frame = @serialize.call(event))
            stream.write(frame)
          end
        end
      end
    end
  end
end

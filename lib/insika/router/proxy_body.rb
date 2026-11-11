# frozen_string_literal: true

module Insika
  module Router
    # Streams an upstream `Protocol::HTTP::Response` body back to the
    # downstream client. Exposes `#call(stream)`, NOT `#each` — the same
    # discovery `Server::SSEBody` documents: under protocol-rack/protocol-http1
    # (the stack of Async::HTTP::Server AND Falcon), a body that only responds
    # to `#each` is routed to `Body::Enumerable`, whose `read` runs the `#each`
    # in a plain Enumerator Fiber where `Async::Task.current` is unavailable —
    # so a long-running SSE turn proxied through this router would come out
    # empty. `#call` routes it to `Body::Streaming` instead, scheduled via
    # `Fiber.schedule` under the reactor, which is what makes an SSE stream
    # drain through the router with no added buffering beyond the one-time
    # request-body read (§6.5).
    #
    # `on_done` runs exactly once, when the body finishes streaming or is closed
    # without ever streaming (client gone first). The App uses it to count the
    # requests still in flight, so a stopping router can wait for them.
    class ProxyBody
      def initialize(upstream_body, on_done: nil)
        @upstream_body = upstream_body
        @on_done = on_done
      end

      def call(stream)
        @upstream_body.each { |chunk| stream.write(chunk) }
      rescue StandardError
        # The downstream client disconnected, or the upstream connection
        # dropped mid-stream: no exception escapes (same rule as SSEBody) —
        # the turn itself belongs to the backend, not this connection.
        nil
      ensure
        @upstream_body.close
        stream.close
        done
      end

      def close = done

      private

      def done
        callback = @on_done
        @on_done = nil
        callback&.call
      end
    end
  end
end

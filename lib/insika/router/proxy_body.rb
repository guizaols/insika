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
    class ProxyBody
      def initialize(upstream_body)
        @upstream_body = upstream_body
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
      end
    end
  end
end

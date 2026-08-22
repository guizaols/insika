# frozen_string_literal: true

require "json"
require "rack/request"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http/body/buffered"
require_relative "session_key"
require_relative "proxy_body"

module Insika
  module Router
    # The standalone Rack/Async app (RFC-0043 §3): session-key extraction →
    # consistent-hash pick → proxy, on the same Async/Falcon stack the engine
    # already runs on. A request whose key has no live owner (nothing found,
    # or the ring itself is empty) round-robins; a request whose chosen
    # backend is unreachable answers the RFC-0021 retry envelope — it is NOT
    # retried against a different backend (§3.5): that backend may already
    # hold a durable, at-most-once claim on the task this request names.
    class App
      DEFAULT_BODY_MAX_BYTES = 262_144 # 256 KiB — small JSON control payloads, never uploads (§5)
      RETRY_AFTER_SECONDS = 1
      HOP_BY_HOP = %w[connection keep-alive proxy-connection transfer-encoding upgrade host content-length].freeze

      # client_factory: (backend_url, timeout) -> an object answering #call(request)
      # -> Protocol::HTTP::Response. Defaults to a real Async::HTTP::Client;
      # a spec injects a fake instead of opening real sockets.
      def initialize(pool:, body_max_bytes: DEFAULT_BODY_MAX_BYTES, backend_timeout: 10, logger: $stdout,
                     client_factory: DEFAULT_CLIENT_FACTORY)
        @pool = pool
        @body_max_bytes = body_max_bytes
        @backend_timeout = backend_timeout
        @logger = logger
        @client_factory = client_factory
        @clients = {} # backend address -> memoized client (persistent connections)
        @clients_mutex = Mutex.new
        @rr_index = -1
      end

      DEFAULT_CLIENT_FACTORY = lambda do |backend, timeout|
        Async::HTTP::Client.new(Async::HTTP::Endpoint.parse(backend, timeout: timeout))
      end
      private_constant :DEFAULT_CLIENT_FACTORY

      def call(env)
        req = Rack::Request.new(env)
        segments = req.path_info.split("/").reject(&:empty?)

        return health_response if req.request_method == "GET" && segments == ["up"]

        raw_body = read_body(env)
        backend = pick_backend(req.request_method, segments, raw_body)
        return unavailable_response if backend.nil?

        proxy(req, backend, raw_body)
      end

      private

      def pick_backend(method, segments, raw_body)
        backends = @pool.backends
        return nil if backends.empty?

        key = session_key(method, segments, raw_body)
        return @pool.ring.backend_for(key) if key

        @rr_index = (@rr_index + 1) % backends.size
        backends[@rr_index]
      end

      def session_key(method, segments, raw_body)
        return nil if raw_body.nil?

        if raw_body.bytesize > @body_max_bytes
          log("router: body #{raw_body.bytesize}B exceeds body_max_bytes=#{@body_max_bytes} — " \
              "skipping session-key extraction (round-robin), forwarding it whole regardless")
          return nil
        end

        SessionKey.extract(method, segments, body: -> { JSON.parse(raw_body) })
      end

      # Reads the WHOLE body (it must be forwarded intact) — `body_max_bytes`
      # only bounds how much of it #session_key will try to parse as JSON,
      # never how much reaches the backend (§3.1, §5).
      def read_body(env)
        input = env["rack.input"]
        return nil if input.nil?

        data = input.read
        input.rewind if input.respond_to?(:rewind)
        data.nil? || data.empty? ? nil : data
      end

      def proxy(req, backend, raw_body)
        client = client_for(backend)
        path = req.script_name.to_s + req.path_info
        path += "?#{req.query_string}" unless req.query_string.to_s.empty?
        body = raw_body ? Protocol::HTTP::Body::Buffered.wrap(raw_body) : nil

        response = client.call(
          Protocol::HTTP::Request.new(nil, nil, req.request_method, path, nil,
                                      forward_headers(req), body)
        )
        [response.status, response_headers(response), response.body ? ProxyBody.new(response.body) : []]
      rescue StandardError => e
        log("router: backend #{backend} unreachable (#{e.class}: #{e.message})")
        unavailable_response
      end

      def client_for(backend)
        @clients_mutex.synchronize { @clients[backend] ||= @client_factory.call(backend, @backend_timeout) }
      end

      def forward_headers(req)
        headers = Protocol::HTTP::Headers.new
        req.each_header do |key, value|
          next unless key.start_with?("HTTP_")

          name = key.sub(/\AHTTP_/, "").tr("_", "-").downcase
          headers.add(name, value) unless HOP_BY_HOP.include?(name)
        end
        headers.add("content-type", req.content_type) if req.content_type
        headers
      end

      def response_headers(response)
        headers = {}
        response.headers&.each do |key, value|
          name = key.to_s
          headers[name] = headers.key?(name) ? Array(headers[name]) + [value] : value
        end
        headers
      end

      def health_response
        json_response(200, { status: "ok", backends: @pool.backends.size })
      end

      def unavailable_response
        json_response(503, { error: { class: "Insika::Router::BackendUnavailable",
                                       message: "no backend reachable",
                                       retryable: true, retry_after: RETRY_AFTER_SECONDS } })
      end

      def json_response(status, body)
        [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
      end

      def log(message)
        @logger&.puts(message)
      rescue StandardError
        nil
      end
    end
  end
end

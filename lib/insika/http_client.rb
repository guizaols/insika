# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "coercion"

module Insika
  # Default HTTP client for data-tools. Net::HTTP (stdlib, zero-dep — spec)
  # with its own socket timeouts (mitigates reactor blocking even if the
  # envelope timer doesn't fire) and a response-size CAP via streaming (
  # avoids OOM). It is INJECTABLE: tests pass a double (none hit the network);
  # can swap in async-http without touching DataDefinedTool.
  #
  # Contract: request(method:, url:, headers:, body:, timeout:) -> { status:, body: }
  # (+ `location:` on a 3xx). It does NOT follow redirects: the destination is
  # cleared by the EgressGuard in the CALLER (DataDefinedTool), before the call —
  # a hop taken in here would carry the model's tool call to a host nobody
  # allowed (an SSRF around the guard). A data-tool whose API moved gets a
  # 3xx surfaced as an error naming the new URL, and the fix is to author the
  # final URL in the definition.
  class HttpClient
    DEFAULT_TIMEOUT = 30
    MAX_BYTES = 1_000_000 # 1 MB

    class ResponseTooLarge < Insika::Error; end

    DNS_TTL = 60 # seconds
    # A connection idle longer than this is reopened instead of reused. Kept well
    # under common server idle timeouts: Net::HTTP retries only idempotent methods,
    # so a POST on a socket the server already closed would fail the tool call.
    KEEP_ALIVE = 5 # seconds
    MAX_IDLE_PER_HOST = 16

    def initialize(max_bytes: MAX_BYTES, dns_ttl: DNS_TTL, keep_alive: KEEP_ALIVE)
      @max_bytes = max_bytes
      @dns_ttl = dns_ttl
      @keep_alive = keep_alive
      @dns = {}
      @idle = Hash.new { |h, k| h[k] = [] }
      @pid = Process.pid
      @lock = Mutex.new
    end

    def request(method:, url:, headers: {}, body: nil, timeout: nil)
      uri = URI.parse(url)
      req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body && !body.to_s.empty?

      with_connection(uri, timeout || DEFAULT_TIMEOUT) do |http|
        result = nil
        http.request(req) do |resp|
          # Accumulate in BINARY: Net::HTTP yields ASCII-8BIT chunks and a
          # multi-byte character can straddle two of them, so only byte
          # concatenation is safe here. (A `+""` buffer would also SILENTLY turn
          # BINARY the first time a chunk carried a non-ASCII byte.)
          collected = +"".b
          resp.read_body do |chunk|
            collected << chunk
            raise ResponseTooLarge, "response exceeds #{@max_bytes} bytes" if collected.bytesize > @max_bytes
          end
          # One tag at the end, over whole bytes: the body leaves here as valid
          # UTF-8 (see Coercion.utf8) because it goes on to be a tool result —
          # transcript, event, SSE frame — and JSON.generate rejects anything else.
          result = { status: resp.code.to_i, body: Coercion.utf8(collected) }
          # The redirect TARGET, so a moved API is reported as "moved to <url>"
          # instead of a bare 3xx with the empty body servers send with it.
          result[:location] = resp["location"].to_s if resp["location"]
          # The server's own processing time (Rack::Runtime's X-Runtime, seconds),
          # so a slow call can be split into server work and everything else.
          runtime = Float(resp["x-runtime"], exception: false)
          result[:server_ms] = (runtime * 1000).round if runtime
        end
        result
      end
    end

    private

    # Reuses an idle keep-alive connection to the same origin (a new TLS connection
    # costs several round trips). One caller holds a connection at a time; one that
    # raised is closed, never returned, since its state is unknown.
    def with_connection(uri, timeout)
      key = [uri.scheme, uri.host, uri.port]
      http = checkout(key) || connect(uri, timeout)
      http.read_timeout = timeout
      result = yield http
      checkin(key, http)
      result
    rescue StandardError
      http&.finish if http&.started?
      raise
    end

    def connect(uri, timeout)
      # `ipaddr` connects to the cached address; TLS (SNI, certificate check) and the
      # Host header still use the hostname.
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = address(uri.host)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.keep_alive_timeout = @keep_alive
      http.start
    end

    def checkout(key)
      @lock.synchronize do
        reset_after_fork
        @idle[key].pop
      end
    end

    def checkin(key, http)
      kept = @lock.synchronize do
        next false if @idle[key].size >= MAX_IDLE_PER_HOST

        @idle[key].push(http)
        true
      end
      http.finish unless kept
    end

    # A forked child must not share its parent's sockets.
    def reset_after_fork
      return if @pid == Process.pid

      @pid = Process.pid
      @idle.clear
    end

    # Net::HTTP resolves with getaddrinfo, which blocks the whole reactor under
    # Falcon: a burst of N tool calls queued N lookups and froze every turn of the
    # process meanwhile. Resolving once per host per TTL makes that rare.
    # ponytail: the lookup on a miss still blocks; a fiber-aware resolver removes it
    # if one host per minute ever shows up in a profile.
    def address(host)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      hit = @lock.synchronize { @dns[host] }
      return hit[0] if hit && hit[1] > now

      ip = Addrinfo.getaddrinfo(host, nil, nil, :STREAM).first.ip_address
      @lock.synchronize { @dns[host] = [ip, now + @dns_ttl] }
      ip
    end
  end
end

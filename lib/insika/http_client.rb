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

    def initialize(max_bytes: MAX_BYTES)
      @max_bytes = max_bytes
    end

    def request(method:, url:, headers: {}, body: nil, timeout: nil)
      uri = URI.parse(url)
      req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body && !body.to_s.empty?

      t = timeout || DEFAULT_TIMEOUT
      opts = { use_ssl: uri.scheme == "https", open_timeout: t, read_timeout: t }
      Net::HTTP.start(uri.host, uri.port, opts) do |http|
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
        end
        result
      end
    end
  end
end

# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "coercion"

module Insika
  # Default HTTP client for data-tools. Net::HTTP (stdlib, zero-dep — spec §10)
  # with its own socket timeouts (mitigates reactor blocking even if the
  # envelope timer doesn't fire) and a response-size CAP via streaming (NF2,
  # avoids OOM). It is INJECTABLE: tests pass a double (none hit the network);
  # Stage C can swap in async-http without touching DataDefinedTool.
  #
  # Contract: request(method:, url:, headers:, body:, timeout:) -> { status:, body: }.
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
        end
        result
      end
    end
  end
end

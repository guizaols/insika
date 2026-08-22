# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "../../../lib/insika/router/app"
require_relative "../../../lib/insika/router/hash_ring"

RSpec.describe Insika::Router::App do
  # A pool double backed by a real HashRing (so backend_for is the real
  # consistent-hash algorithm) but with a controllable backend list.
  RouterFakePool = Struct.new(:backends) do
    def ring = Insika::Router::HashRing.new(backends)
  end

  # A fake `Protocol::HTTP::Response`: status/headers/body, where body is
  # any object answering #each and #close (a Buffered body is exactly that).
  RouterFakeResponse = Struct.new(:status, :headers, :body)

  # client_factory double: records every request it received, keyed by the
  # backend it was built for, and answers a queued response (or raises the
  # queued error — simulating an unreachable backend, RFC-0043 §3.5).
  class RouterFakeClientFactory
    Call = Struct.new(:backend, :request)

    def initialize
      @calls = []
      @responses = {} # backend -> response | error
    end

    attr_reader :calls

    def respond(backend, response_or_error)
      @responses[backend] = response_or_error
    end

    def to_proc
      factory = self
      ->(backend, _timeout) { RouterFakeClient.new(factory, backend) }
    end

    def record(backend, request) = @calls << Call.new(backend, request)

    def answer_for(backend)
      answer = @responses.fetch(backend) { RouterFakeResponse.new(200, Protocol::HTTP::Headers.new, Protocol::HTTP::Body::Buffered.wrap("ok")) }
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  RouterFakeClient = Struct.new(:factory, :backend) do
    def call(request)
      factory.record(backend, request)
      factory.answer_for(backend)
    end
  end

  def rack_env(method:, path:, body: nil, headers: {})
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "SCRIPT_NAME" => "",
      "QUERY_STRING" => "", "rack.input" => StringIO.new(body.to_s)
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env["CONTENT_TYPE"] = "application/json" if body
    env
  end

  def read_body(triple)
    _status, _headers, body = triple
    return body.join if body.respond_to?(:join) # array body (health/unavailable)

    chunks = []
    stream = Struct.new(:chunks) do
      def write(chunk) = chunks << chunk
      def close = nil
    end.new(chunks)
    body.call(stream)
    chunks.join
  end

  describe "GET /up" do
    it "answers 200 without consulting the pool's ring" do
      pool = RouterFakePool.new(%w[http://a:9292])
      app = described_class.new(pool: pool, logger: nil)

      status, headers, body = app.call(rack_env(method: "GET", path: "/up"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(JSON.parse(body.join)["status"]).to eq("ok")
    end
  end

  describe "session-sticky routing" do
    it "the same session id always reaches the same backend" do
      pool = RouterFakePool.new(%w[http://a:9292 http://b:9292 http://c:9292])
      factory = RouterFakeClientFactory.new
      app = described_class.new(pool: pool, logger: nil, client_factory: factory.to_proc)

      2.times { app.call(rack_env(method: "POST", path: "/v1/responses", body: JSON.generate(user: "sess-1"))) }

      expect(factory.calls.map(&:backend).uniq.size).to eq(1)
    end

    it "round-robins requests with no session key across all backends" do
      pool = RouterFakePool.new(%w[http://a:9292 http://b:9292])
      factory = RouterFakeClientFactory.new
      app = described_class.new(pool: pool, logger: nil, client_factory: factory.to_proc)

      4.times { app.call(rack_env(method: "GET", path: "/studio/x")) }

      expect(factory.calls.map(&:backend)).to eq(%w[http://a:9292 http://b:9292 http://a:9292 http://b:9292])
    end

    it "forwards the request line, headers and full body to the chosen backend" do
      pool = RouterFakePool.new(%w[http://a:9292])
      factory = RouterFakeClientFactory.new
      app = described_class.new(pool: pool, logger: nil, client_factory: factory.to_proc)

      app.call(rack_env(method: "POST", path: "/v1/responses", body: JSON.generate(user: "sess-1"),
                         headers: { "authorization" => "Bearer tok" }))

      request = factory.calls.first.request
      expect(request.method).to eq("POST")
      expect(request.path).to eq("/v1/responses")
      expect(request.headers["authorization"]).to eq("Bearer tok")
      expect(request.body.read).to eq(JSON.generate(user: "sess-1"))
    end
  end

  describe "backend unavailable (RFC-0043 §3.5)" do
    it "answers the RFC-0021 retry envelope instead of trying another backend" do
      pool = RouterFakePool.new(%w[http://a:9292 http://b:9292])
      factory = RouterFakeClientFactory.new
      factory.respond("http://a:9292", Errno::ECONNREFUSED.new)
      app = described_class.new(pool: pool, logger: nil, client_factory: factory.to_proc)

      status, _headers, body = app.call(rack_env(method: "POST", path: "/v1/responses", body: JSON.generate(user: "sess-1")))
      envelope = JSON.parse(body.join)

      expect(status).to eq(503)
      expect(envelope["error"]["retryable"]).to be true
      expect(envelope["error"]).to have_key("retry_after")
      # exactly one attempt — never re-tried against backend "b"
      expect(factory.calls.map(&:backend)).to eq(["http://a:9292"])
    end

    it "answers unavailable with an empty ring, without ever building a request" do
      pool = RouterFakePool.new([])
      factory = RouterFakeClientFactory.new
      app = described_class.new(pool: pool, logger: nil, client_factory: factory.to_proc)

      status, = app.call(rack_env(method: "GET", path: "/up".sub("up", "studio/x")))
      expect(status).to eq(503)
      expect(factory.calls).to be_empty
    end
  end

  describe "oversized body (RFC-0043 §5 — a bounded peek, not a bounded forward)" do
    it "skips session-key extraction past body_max_bytes but still forwards the WHOLE body" do
      pool = RouterFakePool.new(%w[http://a:9292 http://b:9292])
      factory = RouterFakeClientFactory.new
      app = described_class.new(pool: pool, logger: nil, client_factory: factory.to_proc, body_max_bytes: 10)

      big_payload = JSON.generate(user: "sess-1", filler: "x" * 100)
      app.call(rack_env(method: "POST", path: "/v1/responses", body: big_payload))

      expect(factory.calls.first.request.body.read).to eq(big_payload)
    end
  end

  describe "streaming response bodies (SSE passthrough, §6.5)" do
    it "streams every upstream chunk through, in order" do
      pool = RouterFakePool.new(%w[http://a:9292])
      factory = RouterFakeClientFactory.new
      chunks = ["data: one\n\n", "data: two\n\n"]
      factory.respond("http://a:9292", RouterFakeResponse.new(200, Protocol::HTTP::Headers.new, Protocol::HTTP::Body::Buffered.new(chunks.dup)))
      app = described_class.new(pool: pool, logger: nil, client_factory: factory.to_proc)

      triple = app.call(rack_env(method: "POST", path: "/v1/responses", body: JSON.generate(user: "sess-1")))
      expect(read_body(triple)).to eq(chunks.join)
    end
  end
end

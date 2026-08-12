# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ProviderErrorClassifier do
  # A response double with the three members the classifier reads.
  def fake_response(status, headers = {})
    response = Object.new
    response.define_singleton_method(:status) { status }
    response.define_singleton_method(:headers) { headers }
    response.define_singleton_method(:body) { "provider says no" }
    response
  end

  describe ".classify" do
    it ":fatal for the auth/billing/request family — non-retryable, no retry_after" do
      {
        RubyLLM::UnauthorizedError => "bad key",
        RubyLLM::PaymentRequiredError => "no balance",
        RubyLLM::ForbiddenError => "forbidden",
        RubyLLM::BadRequestError => "bad input",
        RubyLLM::ContextLengthExceededError => "too long"
      }.each do |klass, message|
        c = described_class.classify(klass.new(message))
        expect(c.kind).to eq(:fatal), "#{klass}: expected fatal, got #{c.kind}"
        expect(c.retryable).to be(false)
        expect(c.retry_after).to be_nil
      end
    end

    it ":retryable for the 5xx/529 family with the default retry_after" do
      [RubyLLM::ServerError, RubyLLM::ServiceUnavailableError,
       RubyLLM::OverloadedError].each do |klass|
        c = described_class.classify(klass.new("down"))
        expect(c.kind).to eq(:retryable)
        expect(c.retryable).to be(true)
        expect(c.retry_after).to eq(described_class::DEFAULTS[:retryable])
      end
    end

    it ":retryable for transport failures (socket, DNS, timeout, connection)" do
      [SocketError.new("nodename nor servname"), Errno::ECONNREFUSED.new,
       Errno::ECONNRESET.new, Net::ReadTimeout.new,
       Faraday::ConnectionFailed.new("refused"), Faraday::TimeoutError.new].each do |error|
        c = described_class.classify(error)
        expect(c.kind).to eq(:retryable), "#{error.class}: expected retryable, got #{c.kind}"
        expect(c.retryable).to be(true)
      end
    end

    it "a generic RubyLLM::Error is classified by its HTTP status (503 -> retryable)" do
      error = RubyLLM::Error.new(fake_response(503), "overloaded")
      expect(described_class.classify(error).kind).to eq(:retryable)
    end

    it "429 without a Retry-After header -> :rate_limited_short with the default" do
      error = RubyLLM::RateLimitError.new(fake_response(429), "slow down")
      c = described_class.classify(error)
      expect(c.kind).to eq(:rate_limited_short)
      expect(c.retryable).to be(true)
      expect(c.retry_after).to eq(described_class::DEFAULTS[:rate_limited_short])
    end

    it "429-de-RPM != 429-de-quota: a short Retry-After is short, a long one is long" do
      rpm = RubyLLM::RateLimitError.new(fake_response(429, { "retry-after" => "5" }), "rpm")
      c_rpm = described_class.classify(rpm)
      expect(c_rpm.kind).to eq(:rate_limited_short)
      expect(c_rpm.retry_after).to eq(5)

      quota = RubyLLM::RateLimitError.new(fake_response(429, { "retry-after" => "120" }), "quota")
      c_quota = described_class.classify(quota)
      expect(c_quota.kind).to eq(:rate_limited_long)
      expect(c_quota.retry_after).to eq(120)
    end

    it "an unrecognized error defaults to :fatal — never to retry (the structural rule)" do
      c = described_class.classify(RuntimeError.new("weird"))
      expect(c.kind).to eq(:fatal)
      expect(c.retryable).to be(false)
    end

    it "a RubyLLM::Error with no response also defaults to :fatal" do
      expect(described_class.classify(RubyLLM::Error.new("nothing to see")).kind).to eq(:fatal)
    end
  end

  describe ".provider_error?" do
    it "true for the RubyLLM family (any subclass) and transport errors" do
      expect(described_class.provider_error?(RubyLLM::RateLimitError.new("x"))).to be(true)
      expect(described_class.provider_error?(RubyLLM::ServerError.new("x"))).to be(true)
      expect(described_class.provider_error?(RubyLLM::Error.new("x"))).to be(true)
      expect(described_class.provider_error?(SocketError.new)).to be(true)
    end

    it "false for anything else (the :unknown stage is preserved)" do
      expect(described_class.provider_error?(RuntimeError.new("boom"))).to be(false)
      expect(described_class.provider_error?(Insika::StoreError.new("db"))).to be(false)
    end
  end

  describe ".wrap" do
    it "builds the typed ProviderError the executor stores and emits" do
      error = RubyLLM::RateLimitError.new(fake_response(429, { "retry-after" => "90" }), "quota")
      wrapped = described_class.wrap(error)

      expect(wrapped).to be_a(Insika::ProviderError)
      expect(wrapped.message).to eq("quota")
      expect(wrapped.kind).to eq(:rate_limited_long)
      expect(wrapped.retryable).to be(true)
      expect(wrapped.retry_after).to eq(90)
      expect(wrapped.classification).to eq(kind: :rate_limited_long, retryable: true, retry_after: 90)
    end

    it "a plain ProviderError has an empty classification (adds nothing to the contract)" do
      expect(Insika::ProviderError.new("boom").classification).to eq({})
    end
  end
end
# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/insika/router/backend_pool"

RSpec.describe Insika::Router::BackendPool do
  describe "construction" do
    it "requires exactly one of static: or dns:" do
      expect { described_class.new }.to raise_error(ArgumentError)
      expect { described_class.new(static: %w[http://a], dns: "x", dns_port: 9292) }.to raise_error(ArgumentError)
    end

    it "requires dns_port with dns:" do
      expect { described_class.new(dns: "insika-headless") }.to raise_error(ArgumentError, /dns_port/)
    end

    it "rejects an empty static list" do
      expect { described_class.new(static: []) }.to raise_error(ArgumentError)
    end
  end

  describe "static mode" do
    it "builds a ring immediately and never re-resolves" do
      pool = described_class.new(static: %w[http://a:9292 http://b:9292], logger: nil)
      expect(pool.backends.sort).to eq(%w[http://a:9292 http://b:9292])
      expect(pool.dns?).to be false
    end

    it "#refresh! is a no-op (the set cannot change)" do
      pool = described_class.new(static: %w[http://a:9292], logger: nil)
      expect(pool.refresh!).to be false
    end
  end

  describe "dns mode" do
    # A resolver double: successive calls can return different address sets,
    # driving the "only rebuild when it actually changed" assertion.
    class FakeResolver
      def initialize(*answers)
        @answers = answers
      end

      def getaddresses(_name)
        @answers.size > 1 ? @answers.shift : @answers.first
      end
    end

    it "resolves via the injected resolver and builds a ring" do
      resolver = FakeResolver.new(%w[10.0.0.1 10.0.0.2])
      pool = described_class.new(dns: "insika-headless", dns_port: 9292, resolver: resolver, logger: nil)
      expect(pool.backends.sort).to eq(%w[http://10.0.0.1:9292 http://10.0.0.2:9292])
      expect(pool.dns?).to be true
    end

    it "rebuilds the ring only when the resolved set actually changed" do
      resolver = FakeResolver.new(%w[10.0.0.1], %w[10.0.0.1], %w[10.0.0.1 10.0.0.2])
      pool = described_class.new(dns: "insika-headless", dns_port: 9292, resolver: resolver, logger: nil)
      ring_before = pool.ring

      expect(pool.refresh!).to be false # same set as the initial resolve
      expect(pool.ring).to equal(ring_before) # literally the same ring object — no rebuild

      expect(pool.refresh!).to be true # a pod became ready
      expect(pool.backends.sort).to eq(%w[http://10.0.0.1:9292 http://10.0.0.2:9292])
    end

    it "keeps the previous ring when a resolve returns nothing (transient DNS hiccup)" do
      resolver = FakeResolver.new(%w[10.0.0.1], [])
      pool = described_class.new(dns: "insika-headless", dns_port: 9292, resolver: resolver, logger: nil)

      expect(pool.refresh!).to be false
      expect(pool.backends).to eq(["http://10.0.0.1:9292"])
    end

    it "keeps the previous ring when the resolver itself raises" do
      resolver = Class.new { def getaddresses(_name) = raise("dns down") }.new
      pool = described_class.new(dns: "insika-headless", dns_port: 9292, resolver: FakeResolver.new(%w[10.0.0.1]), logger: nil)
      pool.instance_variable_set(:@resolver, resolver)

      expect { pool.refresh! }.not_to raise_error
      expect(pool.backends).to eq(["http://10.0.0.1:9292"])
    end
  end
end

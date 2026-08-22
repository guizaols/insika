# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/insika/router/hash_ring"

RSpec.describe Insika::Router::HashRing do
  it "is deterministic — the same key always owns the same backend" do
    ring = described_class.new(%w[a b c])
    key = "session-42"
    expect(ring.backend_for(key)).to eq(ring.backend_for(key))
  end

  it "spreads keys across every configured backend" do
    ring = described_class.new(%w[a b c])
    owners = (0...1000).map { |i| ring.backend_for("session-#{i}") }.uniq
    expect(owners.sort).to eq(%w[a b c])
  end

  it "raises with no backends — a router must never silently round-robin an empty ring" do
    expect { described_class.new([]) }.to raise_error(ArgumentError)
  end

  describe "ring stability (RFC-0043 §6.2 — adding/removing one backend remaps ~1/N)" do
    it "adding one backend to N remaps roughly 1/(N+1) of the key space" do
      before = described_class.new(%w[a b c d])
      after = described_class.new(%w[a b c d e])

      fraction = described_class.remapped_fraction(before, after)
      # Ketama's guarantee is asymptotic (fewer replicas -> noisier); 160
      # replicas over 1000s of ring points keeps this comfortably tight
      # around the ideal 1/5 = 0.20.
      expect(fraction).to be_within(0.08).of(1.0 / 5)
    end

    it "removing one backend from N remaps roughly 1/N of the key space" do
      before = described_class.new(%w[a b c d e])
      after = described_class.new(%w[a b c d])

      fraction = described_class.remapped_fraction(before, after)
      expect(fraction).to be_within(0.08).of(1.0 / 5)
    end

    it "does NOT remap the whole ring on a single backend change" do
      before = described_class.new(%w[a b c d])
      after = described_class.new(%w[a b c d e])

      fraction = described_class.remapped_fraction(before, after)
      expect(fraction).to be < 0.5
    end
  end
end

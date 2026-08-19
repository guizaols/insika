# frozen_string_literal: true

require "spec_helper"

# the signed-link half of the artifact serving surface: HMAC-SHA256
# over (id, expiry) with INSIKA_ARTIFACT_SIGNING_KEY. Constant-time verify;
# expired or bad signatures 404 (never 403 — no oracle). Rotating the key
# invalidates outstanding links — the documented behavior, not a bug.
RSpec.describe Insika::ArtifactSigning do
  let(:key) { "k3y" * 8 }
  let(:now) { Time.iso8601("2026-08-19T12:00:00Z") }

  describe ".sign" do
    it "produces a hex token that verifies" do
      token = described_class.sign(id: "a-1", expires_at: now + 3600, key: key)
      expect(token).to match(/\A[0-9a-f]{64}\z/)
      expect(described_class.valid?(id: "a-1", token: token, key: key,
                                    exp: now + 3600, now: now)).to be(true)
    end

    it "the same (id, expiry) signs identically (deterministic)" do
      a = described_class.sign(id: "a-1", expires_at: now + 3600, key: key)
      b = described_class.sign(id: "a-1", expires_at: now + 3600, key: key)
      expect(a).to eq(b)
    end

    it "nil with a blank key (no signed surface exists)" do
      expect(described_class.sign(id: "a-1", expires_at: now + 3600, key: "")).to be_nil
    end
  end

  describe ".valid?" do
    let(:token) { described_class.sign(id: "a-1", expires_at: now + 3600, key: key) }

    it "a different id fails" do
      expect(described_class.valid?(id: "a-2", token: token, key: key,
                                    exp: now + 3600, now: now)).to be(false)
    end

    it "a different key fails (rotation invalidates outstanding links)" do
      expect(described_class.valid?(id: "a-1", token: token, key: "other" * 8,
                                    exp: now + 3600, now: now)).to be(false)
    end

    it "a tampered token fails" do
      bad = token.dup
      bad[0] = bad[0] == "0" ? "1" : "0"
      expect(described_class.valid?(id: "a-1", token: bad, key: key,
                                    exp: now + 3600, now: now)).to be(false)
    end

    it "an expired link fails" do
      expect(described_class.valid?(id: "a-1", token: token, key: key,
                                    exp: now + 3600, now: now + 3601)).to be(false)
    end

    it "a link at its exact expiry still verifies (expiry is the last valid instant)" do
      expect(described_class.valid?(id: "a-1", token: token, key: key,
                                    exp: now + 3600, now: now + 3600)).to be(true)
    end

    it "a garbage token fails without raising" do
      expect(described_class.valid?(id: "a-1", token: "zzz", key: key,
                                    exp: now + 3600, now: now)).to be(false)
      expect(described_class.valid?(id: "a-1", token: nil, key: key,
                                    exp: now + 3600, now: now)).to be(false)
    end

    it "a malformed exp fails without raising" do
      expect(described_class.valid?(id: "a-1", token: token, key: key,
                                    exp: "not-a-time", now: now)).to be(false)
    end

    it "a blank key means no signed surface (false, never a pass)" do
      expect(described_class.valid?(id: "a-1", token: token, key: "",
                                    exp: now + 3600, now: now)).to be(false)
    end
  end

  describe ".url_for" do
    it "builds the signed link when the key + ttl are given" do
      url = described_class.url_for(id: "a-1", base: "https://insika.example",
                                    key: key, ttl: 3600, now: now)
      expect(url).to match(%r{\Ahttps://insika\.example/studio/artifacts/s/a-1\?exp=2026-08-19T13:00:00Z&sig=[0-9a-f]{64}\z})
    end

    it "without a key, the authenticated Studio content URL" do
      url = described_class.url_for(id: "a-1", base: "https://insika.example")
      expect(url).to eq("https://insika.example/studio/artifacts/a-1/content")
    end

    it "an empty base yields the relative path (openable in the Studio, useless on a channel)" do
      expect(described_class.url_for(id: "a-1", base: "")).to eq("/studio/artifacts/a-1/content")
    end

    it "a zero/blank ttl is treated as no signing (never an unbounded link)" do
      url = described_class.url_for(id: "a-1", base: "https://insika.example",
                                    key: key, ttl: 0, now: now)
      expect(url).to eq("https://insika.example/studio/artifacts/a-1/content")
    end
  end
end
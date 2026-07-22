# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Harness ProfileSource (Phase 4 D2)" do
  let(:profile) do
    Harness::AgentProfile.build(
      id: "bia", model: "deepseek-chat", provider: :deepseek,
      tools_allow: %w[menu calc], skills: %w[pedido],
      policies: %i[tool_allowlist skill_allowlist], memory: true,
      limits: { tool_timeout: 30, turn_timeout: 120 }
    )
  end

  describe Harness::StaticProfileSource do
    subject(:src) { described_class.new({ "bia" => profile }) }

    it "[] and fetch return the profile; nil if absent (does not raise)" do
      expect(src["bia"]).to eq(profile)
      expect(src.fetch("bia")).to eq(profile)
      expect(src["sumiu"]).to be_nil
    end

    it "all/ids" do
      expect(src.all).to eq([profile])
      expect(src.ids).to eq(["bia"])
    end
  end

  describe Harness::StoredProfileSource do
    let(:config_store) { Harness::ConfigStore.new(store: Harness::Stores::Memory.new) }
    subject(:src) { described_class.new(config_store: config_store) }

    it "put -> fetch round-trips PRESERVING the symbols (provider/policies/limits)" do
      src.put(profile)
      got = src.fetch("bia")

      # the critical point of D2: JSON round-trip becomes string; we re-symbolize.
      expect(got.provider).to eq(:deepseek)                       # symbol, not "deepseek"
      expect(got.policies).to eq(%i[tool_allowlist skill_allowlist]) # symbols
      expect(got.limits[:tool_timeout]).to eq(30)                 # symbol key + Integer
      expect(got.limits[:turn_timeout]).to eq(120)
      expect(got.tools_allow).to eq(%w[menu calc])
      expect(got.skills).to eq(%w[pedido])
      expect(got.memory).to be(true)
      # limits gets the defaults on build (merge)
      expect(got.limits[:max_tool_calls]).to eq(Harness::AgentProfile::DEFAULT_LIMITS[:max_tool_calls])
    end

    it "fetch of absent -> nil; all/ids reflect the store" do
      expect(src.fetch("nope")).to be_nil
      src.put(profile)
      expect(src.ids).to eq(["bia"])
      expect(src.all.map(&:id)).to eq(["bia"])
    end

    it "delete removes the profile" do
      src.put(profile)
      expect(src.delete("bia")).to be(true)
      expect(src.fetch("bia")).to be_nil
    end

    it "each fetch reads FRESH (edits apply without rebuilding the source)" do
      src.put(profile)
      src.put(Harness::AgentProfile.build(id: "bia", model: "novo-modelo"))
      expect(src.fetch("bia").model).to eq("novo-modelo")
    end

    it "round-trip of metadata (store_id from the turn context, Phase 6)" do
      src.put(Harness::AgentProfile.build(id: "loja", model: "m", metadata: { store_id: "loja-7" }))
      got = src.fetch("loja")
      expect(got.store_id).to eq("loja-7") # survives the JSON round-trip (key becomes string)
    end

    it "round-trip of tools_allow_groups (Phase 7/D4/F5, Step C)" do
      src.put(Harness::AgentProfile.build(id: "loja", model: "m", tools_allow_groups: %w[b2b beauty]))
      expect(src.fetch("loja").tools_allow_groups).to eq(%w[b2b beauty])
    end

    it "round-trip of params/model_policy (LLM config v2, §10)" do
      src.put(Harness::AgentProfile.build(
                id: "loja", model: "m",
                params: { temperature: 0.2, max_tokens: 300 },
                model_policy: { "allow" => ["deepseek/*"] }
              ))
      got = src.fetch("loja")
      # params survive as a Hash the resolver consumes (keys become strings via JSON;
      # ModelResolver#normalize_params re-symbolizes); model_policy stays as authored.
      expect(got.params).to eq("temperature" => 0.2, "max_tokens" => 300)
      expect(Harness::ModelPolicy.allowed?(got.model_policy, model: "deepseek-chat", provider: :deepseek)).to be(true)
    end

    it "round-trip of a modelless agent (model optional, §10)" do
      src.put(Harness::AgentProfile.build(id: "loja")) # no model
      expect(src.fetch("loja").model).to be_nil
    end

    it "round-trip of guardrails config (RFC-0009), consumed via Safety::Config" do
      src.put(Harness::AgentProfile.build(
                id: "loja", model: "m",
                guardrails: { input: true, output: false, moderator: "on", strictness: "high" }
              ))
      got = src.fetch("loja")
      # keys become strings via JSON; Safety::Config tolerates the round-trip.
      cfg = Harness::Safety::Config.from_profile(got)
      expect(cfg.input).to be(true)
      expect(cfg.output).to be(false)
      expect(cfg.strictness).to eq(:high)
      expect(cfg.moderator).to eq("on")
    end

    it "guardrails absent -> nil (opt-in default applies at read time)" do
      src.put(Harness::AgentProfile.build(id: "loja", model: "m"))
      expect(src.fetch("loja").guardrails).to be_nil
    end

    it "round-trip of sandbox config (item 35), consumed via Sandbox.build" do
      src.put(Harness::AgentProfile.build(
                id: "loja", model: "m",
                sandbox: { provider: "docker", image: "ruby:3.3", network: "none" }
              ))
      got = src.fetch("loja")
      # keys become strings via JSON; Sandbox.build tolerates the round-trip.
      expect(got.sandbox).to eq("provider" => "docker", "image" => "ruby:3.3", "network" => "none")
      env = Harness::Sandbox.build(got.sandbox.merge("root" => Dir.pwd))
      expect(env.provider).to be_a(Harness::Sandbox::Docker)
    end

    it "sandbox absent -> nil (a deployment builds a local sandbox by default)" do
      src.put(Harness::AgentProfile.build(id: "loja", model: "m"))
      expect(src.fetch("loja").sandbox).to be_nil
    end
  end

  describe ".coerce" do
    it "Hash -> StaticProfileSource; ProfileSource passa direto" do
      static = Harness::ProfileSource.coerce({ "bia" => profile })
      expect(static).to be_a(Harness::StaticProfileSource)
      expect(static["bia"]).to eq(profile)

      stored = Harness::StoredProfileSource.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new))
      expect(Harness::ProfileSource.coerce(stored)).to be(stored)
    end

    it "nil -> empty StaticProfileSource (parity with empty Hash)" do
      expect(Harness::ProfileSource.coerce(nil)["x"]).to be_nil
    end
  end
end

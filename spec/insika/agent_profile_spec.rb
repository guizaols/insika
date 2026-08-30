# frozen_string_literal: true

RSpec.describe Insika::AgentProfile do
  describe "compatibility with" do
    it "accepts the minimal signature" do
      profile = described_class.build(id: "a", model: "m")
      expect(profile.id).to eq("a")
      expect(profile.model).to eq("m")
      expect(profile.provider).to be_nil
      expect(profile.base_prompt).to eq("")
      expect(profile.prompt_files).to eq([])
      expect(profile.tools_allow).to be_nil
      expect(profile.tools_deny).to eq([])
      expect(profile.skills).to be_nil
    end

    describe "#tool_opted_in? (preserved)" do
      it "true when the name is in allow" do
        profile = described_class.build(id: "a", model: "m", tools_allow: ["a"])
        expect(profile.tool_opted_in?("a")).to be(true)
        expect(profile.tool_opted_in?("b")).to be(false)
      end

      it "false with tools_allow nil" do
        profile = described_class.build(id: "a", model: "m")
        expect(profile.tool_opted_in?("a")).to be(false)
      end
    end
  end

  describe "new fields" do
    let(:profile) { described_class.build(id: "a", model: "m") }

    it "has correct defaults" do
      expect(profile.context_providers).to be_nil
      expect(profile.workflows_allow).to be_nil
      expect(profile.policies).to eq([])
      expect(profile.prompt_refs).to eq([])
      expect(profile.limits).to eq(described_class::DEFAULT_LIMITS)
      expect(profile.prompt_caching).to be_nil # R3: opt-in, off by default
      expect(profile.tool_output_compression).to be_nil # A3/C3: opt-in, off by default
      expect(profile.budget).to be_nil # WS2: no budget (parity)
      expect(profile.reliability).to be_nil # WS3: plain single ask (parity)
      expect(profile.alerts).to be_nil # WS6: no webhook (parity)
      expect(profile.stuck_signal).to be_nil # WS5: opt-in, off by default
    end

    it "stuck_signal round-trips on/off (the gate the ChatBuilder reads)" do
      off = described_class.build(id: "a", model: "m")
      on = described_class.build(id: "a", model: "m", stuck_signal: true)
      expect(off.stuck_signal).to be_nil
      expect(on.stuck_signal).to be(true)
    end

    it "stt_prompt: nil/absent = the deployment default (parity); blank normalizes to nil" do
      expect(profile.stt_prompt).to be_nil
      blank = described_class.build(id: "a", model: "m", stt_prompt: "  ")
      expect(blank.stt_prompt).to be_nil
    end

    it "stt_prompt round-trips the agent's vocabulary hint" do
      with_prompt = described_class.build(id: "a", model: "m",
                                          stt_prompt: "Ocean Drop, tênis, boné trucker")
      expect(with_prompt.stt_prompt).to eq("Ocean Drop, tênis, boné trucker")
    end

    it "alerts is normalized to string keys (the shape the AlertDispatcher reads)" do
      profile = described_class.build(id: "a", model: "m",
                                      alerts: { webhook: "https://ops.example.com/alerts" })
      expect(profile.alerts).to eq("webhook" => "https://ops.example.com/alerts")
    end

    it "reliability is normalized to string keys (the data shape the edge reads)" do
      profile = described_class.build(
        id: "a", model: "m",
        reliability: { retries: 3, backoff: "exponential",
                       fallback: ["openai/gpt-4o-mini"],
                       circuit_breaker: { after: 10, within: 60, cooldown: 300 } }
      )
      expect(profile.reliability).to eq(
        "retries" => 3, "backoff" => "exponential",
        "fallback" => ["openai/gpt-4o-mini"],
        "circuit_breaker" => { "after" => 10, "within" => 60, "cooldown" => 300 }
      )
    end

    it "budget is normalized to string keys (the data shape the edge reads)" do
      profile = described_class.build(id: "a", model: "m",
                                      budget: { daily: 100_000, monthly: 2_000_000,
                                                soft: true, alert_at: 0.8 })
      expect(profile.budget).to eq("daily" => 100_000, "monthly" => 2_000_000,
                                   "soft" => true, "alert_at" => 0.8)
    end

    it "tool_persistence round-trips (the ONE opt-out flag: nil = ON, false = OFF)" do
      default = described_class.build(id: "a", model: "m")
      off = described_class.build(id: "a", model: "m", tool_persistence: false)

      expect(default.tool_persistence).to be_nil # absent -> ON (opt-out, not opt-in)
      expect(off.tool_persistence).to be(false)
    end

    it "tool_output_compression round-trips on/off" do
      off = described_class.build(id: "a", model: "m")
      on = described_class.build(id: "a", model: "m", tool_output_compression: true)

      expect(off.tool_output_compression).to be_nil # absent -> off (parity)
      expect(on.tool_output_compression).to be(true)
    end

    it "DEFAULT_LIMITS matches (+ approval_timeout from, tool_concurrency from)" do
      expect(described_class::DEFAULT_LIMITS).to eq(
        turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
        context_budget: 8_000, max_tool_calls: 50, max_tool_repeat: 3,
        approval_timeout: 3_600, tool_concurrency: 1
      )
    end

    it "limits does a partial merge, not a replacement" do
      # value distinct from any default so the override doesn't coincide with
      # a preserved key (tool_timeout is also 60 by default).
      profile = described_class.build(id: "a", model: "m", limits: { turn_timeout: 999 })
      expect(profile.limits).to eq(described_class::DEFAULT_LIMITS.merge(turn_timeout: 999))
    end
  end

  describe "Array() normalization" do
    it "accepts a single value in tools_deny, policies and prompt_refs" do
      profile = described_class.build(
        id: "a", model: "m", tools_deny: "x", policies: "p", prompt_refs: "r"
      )
      expect(profile.tools_deny).to eq(["x"])
      # the declared deny list also opts the profile into tool_allowlist
      expect(profile.policies).to eq(["p", "tool_allowlist"])
      expect(profile.prompt_refs).to eq(["r"])
    end
  end

  # Declaring a tool list IS opting into the policy that applies it. Without
  # this, a profile with `tools_allow: [...]` and no policies sent every
  # registered tool to the model, silently.
  describe "tool_allowlist implicit opt-in" do
    it "adds the policy when tools_allow is declared and policies is empty" do
      profile = described_class.build(id: "a", model: "m", tools_allow: %w[x y])
      expect(profile.policies).to eq(["tool_allowlist"])
    end

    it "adds it for an EMPTY tools_allow too ([] = no tools, and that must enforce)" do
      profile = described_class.build(id: "a", model: "m", tools_allow: [])
      expect(profile.policies).to eq(["tool_allowlist"])
    end

    it "adds it for tools_deny alone" do
      profile = described_class.build(id: "a", model: "m", tools_deny: ["x"])
      expect(profile.policies).to eq(["tool_allowlist"])
    end

    it "adds it for tools_allow_groups alone" do
      profile = described_class.build(id: "a", model: "m", tools_allow_groups: ["mcp:crm"])
      expect(profile.policies).to eq(["tool_allowlist"])
    end

    it "appends, keeping the profile-declared order" do
      profile = described_class.build(id: "a", model: "m", tools_allow: ["x"],
                                      policies: %w[approval_required skill_allowlist])
      expect(profile.policies).to eq(%w[approval_required skill_allowlist tool_allowlist])
    end

    it "does not duplicate one already declared (string or symbol)" do
      as_string = described_class.build(id: "a", model: "m", tools_allow: ["x"],
                                        policies: ["tool_allowlist"])
      as_symbol = described_class.build(id: "a", model: "m", tools_allow: ["x"],
                                        policies: [:tool_allowlist])
      expect(as_string.policies).to eq(["tool_allowlist"])
      expect(as_symbol.policies).to eq([:tool_allowlist])
    end

    it "leaves policies untouched when no list is declared (tools_deny defaults to [])" do
      expect(described_class.build(id: "a", model: "m").policies).to eq([])
      expect(described_class.build(id: "a", model: "m", policies: ["approval_required"]).policies)
        .to eq(["approval_required"])
    end
  end

  describe "capabilities — opt-in asymmetry" do
    it "default nil = NO capability (not 'all', unlike tools_allow)" do
      expect(described_class.build(id: "a", model: "m").capabilities).to be_nil
    end

    it "accepts the explicit list of intents" do
      profile = described_class.build(id: "a", model: "m", capabilities: [:browse, :search])
      expect(profile.capabilities).to eq([:browse, :search])
    end

    it " profile (without the kwarg) is still buildable" do
      expect { described_class.build(id: "a", model: "m") }.not_to raise_error
    end
  end

  describe "tools_deferred (Tool Search)" do
    it "default nil = no deferred (all eager — parity)" do
      expect(described_class.build(id: "a", model: "m").tools_deferred).to be_nil
    end

    it "accepts the allowlist of searchable-not-wired tools" do
      profile = described_class.build(id: "a", model: "m", tools_deferred: %w[send_email create_invoice])
      expect(profile.tools_deferred).to eq(%w[send_email create_invoice])
    end
  end

  describe "memory (cross-session memory) — opt-in" do
    it "default nil = OFF (parity)" do
      expect(described_class.build(id: "a", model: "m").memory).to be_nil
    end

    it "accepts memory: true (on)" do
      expect(described_class.build(id: "a", model: "m", memory: true).memory).to be(true)
    end
  end

  describe "subagents (capacity field — never inherits)" do
    it "defaults to nil (opt-in: NONE, like capabilities)" do
      expect(described_class.build(id: "a", model: "m").subagents).to be_nil
    end

    it "normalizes a present value to [String] (accepts symbols)" do
      profile = described_class.build(id: "a", model: "m", subagents: [:researcher, "writer"])
      expect(profile.subagents).to eq(%w[researcher writer])
    end

    it "an explicit empty list stays [] (present but no children)" do
      expect(described_class.build(id: "a", model: "m", subagents: []).subagents).to eq([])
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(id: "a", model: "m", subagents: ["researcher"])
      expect(profile.to_h[:subagents]).to eq(["researcher"])
    end
  end

  describe "briefing_fields (— the session working-state schema)" do
    it "default [] = the feature off (no provider, no tools)" do
      expect(described_class.build(id: "a", model: "m").briefing_fields).to eq([])
      expect(described_class.build(id: "a", model: "m", briefing_fields: nil).briefing_fields).to eq([])
    end

    it "normalizes names to a flat [String] (symbols accepted)" do
      profile = described_class.build(id: "a", model: "m", briefing_fields: [:size, "budget"])
      expect(profile.briefing_fields).to eq(%w[size budget])
    end

    it "trims, drops empties and uniqs in stable order" do
      profile = described_class.build(id: "a", model: "m",
                                      briefing_fields: [" size ", "", "budget", "size", "size"])
      expect(profile.briefing_fields).to eq(%w[size budget])
    end

    it "refuses a malformed name (the names become store keys and tool text)" do
      expect { described_class.build(id: "a", model: "m", briefing_fields: ["size ok"]) }
        .to raise_error(Insika::ValidationError, /briefing_fields/)
      expect { described_class.build(id: "a", model: "m", briefing_fields: ["Tamanho"]) }
        .to raise_error(Insika::ValidationError, /briefing_fields/)
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(id: "a", model: "m", briefing_fields: %w[size budget])
      expect(profile.to_h[:briefing_fields]).to eq(%w[size budget])
    end
  end

  describe "grounding (— the evidence-grounding policy)" do
    it "nil/absent -> nil = the whole feature is OFF (parity, zero allocations)" do
      expect(described_class.build(id: "a", model: "m").grounding).to be_nil
    end

    it "deep-stringifies the config (symbol keys from the DSL round-trip)" do
      profile = described_class.build(
        id: "a", model: "m",
        grounding: { mode: :flag, matcher: { sku: '\b[A-Z]{2,4}\d{4,8}\b' } }
      )
      expect(profile.grounding).to eq("mode" => "flag",
                                      "matcher" => { "sku" => '\b[A-Z]{2,4}\d{4,8}\b' })
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(id: "a", model: "m",
                                      grounding: { "mode" => "enforce", "matcher" => { "sku" => "\\d+" } })
      expect(profile.to_h[:grounding]).to eq("mode" => "enforce", "matcher" => { "sku" => "\\d+" })
    end
  end

  describe "funnel (— the outcome funnel declaration)" do
    it "nil/absent -> nil = no funnel (parity — nothing folds)" do
      expect(described_class.build(id: "a", model: "m").funnel).to be_nil
    end

    it "deep-stringifies the declaration (symbol keys from the DSL round-trip)" do
      profile = described_class.build(
        id: "a", model: "m",
        funnel: { stages: %w[greeted qualified cart paid],
                  advance_on: { pix_paid: "paid", abandoned_cart: "cart" },
                  primary: :paid, attribution_window: "72h" }
      )
      expect(profile.funnel).to eq(
        "stages" => %w[greeted qualified cart paid],
        "advance_on" => { "pix_paid" => "paid", "abandoned_cart" => "cart" },
        "primary" => "paid", "attribution_window" => "72h"
      )
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(
        id: "a", model: "m",
        funnel: { "stages" => %w[greeted paid], "advance_on" => { "conversion" => "paid" },
                  "primary" => "paid", "attribution_window" => "72h" }
      )
      expect(profile.to_h[:funnel]).to eq(
        "stages" => %w[greeted paid], "advance_on" => { "conversion" => "paid" },
        "primary" => "paid", "attribution_window" => "72h"
      )
    end

    it "a profile without a funnel sees nil (no shape validation here)" do
      plain = described_class.build(id: "a", model: "m")
      expect(plain.funnel).to be_nil
    end
  end

  describe "followup (— the follow-up declaration)" do
    it "nil/absent -> nil = feature off (parity)" do
      expect(described_class.build(id: "a", model: "m").followup).to be_nil
    end

    it "deep-stringifies the declaration (symbol keys from the DSL round-trip)" do
      profile = described_class.build(
        id: "a", model: "m",
        followup: { arm: "schedule",
                    policy: { quiet_hours: { timezone: "America/Sao_Paulo",
                                             start: "21:30", end: "09:00" },
                              max_frequency: "2/24h",
                              cancel_keywords: ["não quero mais contato"],
                              silence_after_sends: 3 } }
      )
      expect(profile.followup).to eq(
        "arm" => "schedule",
        "policy" => { "quiet_hours" => { "timezone" => "America/Sao_Paulo",
                                         "start" => "21:30", "end" => "09:00" },
                      "max_frequency" => "2/24h",
                      "cancel_keywords" => ["não quero mais contato"],
                      "silence_after_sends" => 3 }
      )
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(
        id: "a", model: "m",
        followup: { "arm" => "schedule", "policy" => { "max_frequency" => "1/24h" } }
      )
      expect(profile.to_h[:followup]).to eq("arm" => "schedule",
                                            "policy" => { "max_frequency" => "1/24h" })
    end

    it "a profile without a followup declaration sees nil (no shape validation here)" do
      plain = described_class.build(id: "a", model: "m")
      expect(plain.followup).to be_nil
    end
  end

  describe "schedules (the recurring-schedule declarations)" do
    it "nil/absent -> nil = feature off (parity)" do
      expect(described_class.build(id: "a", model: "m").schedules).to be_nil
    end

    it "deep-stringifies the ARRAY (symbol keys from the DSL round-trip)" do
      profile = described_class.build(
        id: "a", model: "m",
        schedules: [{ id: "daily_report", cron: "0 22 * * *", tz: "America/Sao_Paulo",
                      message: "run", overrides: { turn_timeout: 900 } }]
      )
      expect(profile.schedules).to eq(
        [{ "id" => "daily_report", "cron" => "0 22 * * *", "tz" => "America/Sao_Paulo",
           "message" => "run", "overrides" => { "turn_timeout" => 900 } }]
      )
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(
        id: "a", model: "m",
        schedules: [{ "id" => "hb", "every" => 86_400, "message" => "ping" }]
      )
      expect(profile.to_h[:schedules]).to eq(
        [{ "id" => "hb", "every" => 86_400, "message" => "ping" }]
      )
    end

    it "an empty array normalizes to nil (nothing declared)" do
      expect(described_class.build(id: "a", model: "m", schedules: []).schedules).to be_nil
    end
  end

  describe "distill (— the session distillation declaration)" do
    it "nil/absent -> nil = the feature is off (parity)" do
      expect(described_class.build(id: "a", model: "m").distill).to be_nil
    end

    it "deep-stringifies the declaration (symbol keys from the DSL round-trip)" do
      profile = described_class.build(
        id: "a", model: "m",
        distill: { enabled: true, idle_hours: 6, max_proposals: 10 }
      )
      expect(profile.distill).to eq("enabled" => true, "idle_hours" => 6, "max_proposals" => 10)
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(
        id: "a", model: "m",
        distill: { "enabled" => true, "prompt" => "what counts as a fact",
                   "model" => "deepseek-v4-flash" }
      )
      expect(profile.to_h[:distill]).to eq("enabled" => true,
                                           "prompt" => "what counts as a fact",
                                           "model" => "deepseek-v4-flash")
    end

    it "a profile without a distill declaration sees nil (no shape validation here)" do
      plain = described_class.build(id: "a", model: "m")
      expect(plain.distill).to be_nil
    end
  end

  describe "harvest (— the gated harvest declaration)" do
    it "nil/absent -> nil = the loop is off for that agent (parity)" do
      expect(described_class.build(id: "a", model: "m").harvest).to be_nil
    end

    it "deep-stringifies the declaration (symbol keys from the DSL round-trip)" do
      profile = described_class.build(
        id: "a", model: "m",
        harvest: { enabled: true,
                   negative_list: [ { rule: "no-competitor-prices", pattern: "concorrente" } ],
                   miner: { model: "deepseek-v4-flash", window: { last_sessions: 200 } } }
      )
      expect(profile.harvest).to eq("enabled" => true,
                                    "negative_list" => [ { "rule" => "no-competitor-prices",
                                                           "pattern" => "concorrente" } ],
                                    "miner" => { "model" => "deepseek-v4-flash",
                                                 "window" => { "last_sessions" => 200 } })
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(
        id: "a", model: "m",
        harvest: { "enabled" => true, "idle_hours" => 24, "min_messages" => 3 }
      )
      expect(profile.to_h[:harvest]).to eq("enabled" => true, "idle_hours" => 24,
                                           "min_messages" => 3)
    end

    it "a profile without a harvest declaration sees nil (no shape validation here)" do
      plain = described_class.build(id: "a", model: "m")
      expect(plain.harvest).to be_nil
    end
  end

  describe "knowledge (— the post-turn learning declaration)" do
    it "nil/absent -> nil = the loop is off for that agent (parity)" do
      expect(described_class.build(id: "a", model: "m").knowledge).to be_nil
    end

    it "deep-stringifies the declaration (symbol keys from the DSL round-trip)" do
      profile = described_class.build(
        id: "a", model: "m",
        knowledge: { extract: true, retrieve: true, types: %w[fact policy] }
      )
      expect(profile.knowledge).to eq("extract" => true, "retrieve" => true, "types" => %w[fact policy])
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(
        id: "a", model: "m",
        knowledge: { "extract" => true, "model" => "deepseek-v4-flash" }
      )
      expect(profile.to_h[:knowledge]).to eq("extract" => true, "model" => "deepseek-v4-flash")
    end

    it "a profile without a knowledge declaration sees nil (no shape validation here)" do
      plain = described_class.build(id: "a", model: "m")
      expect(plain.knowledge).to be_nil
    end
  end

  describe "metadata + store_id (turn context)" do
    it "default = {} (agent without metadata)" do
      profile = described_class.build(id: "a", model: "m")
      expect(profile.metadata).to eq({})
      expect(profile.store_id).to be_nil
    end

    it "store_id reads from metadata (symbol key)" do
      profile = described_class.build(id: "a", model: "m", metadata: { store_id: "loja-7" })
      expect(profile.store_id).to eq("loja-7")
    end

    it "store_id tolerates string key (store JSON round-trip)" do
      profile = described_class.build(id: "a", model: "m", metadata: { "store_id" => "loja-9" })
      expect(profile.store_id).to eq("loja-9")
    end

    it "metadata: nil becomes {} (doesn't break store_id)" do
      profile = described_class.build(id: "a", model: "m", metadata: nil)
      expect(profile.metadata).to eq({})
      expect(profile.store_id).to be_nil
    end
  end
end

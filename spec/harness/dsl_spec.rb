# frozen_string_literal: true

require "spec_helper"
require "async"

# Public Ruby DSL (item 36 / §13.3). Proves the two things the item is about:
#   1. the DSL GENERATES the data — Harness.agent { … }.to_pack is a plain Pack;
#   2. PARITY — the profile it produces is IDENTICAL to the one a hand-written
#      equivalent pack produces (there is one path: the standard import), so the
#      sugar never diverges from config-over-code.
# Plus the runtime surface (reply/chat) that makes the ≤10-line quickstart real.
RSpec.describe Harness::DSL do
  describe "Harness.agent → data generation (#to_pack)" do
    subject(:pack) do
      Harness.agent("assistant") do
        model "deepseek-chat"
        provider :deepseek
        instructions "You are a concise, friendly assistant."
        tools "menu", "calc"
        skill "escalate", description: "Escalate to a human", instructions: "Hand off when angry."
        memory true
        temperature 0.2
      end.to_pack
    end

    it "is a Harness::Pack carrying the manifest under config" do
      expect(pack).to be_a(Harness::Pack)
      expect(pack.config).to include(
        id: "assistant", model: "deepseek-chat", provider: "deepseek",
        base_prompt: "You are a concise, friendly assistant.",
        tools_allow: %w[menu calc], memory: true
      )
      expect(pack.config[:params]).to eq(temperature: 0.2)
    end

    it "auto-enables the allowlist policies (no hidden magic — visible in the pack)" do
      expect(pack.config[:policies]).to eq(%i[tool_allowlist skill_allowlist])
    end

    it "materializes each skill as a valid SKILL.md (frontmatter + body) and allowlists it" do
      expect(pack.config[:skills]).to eq(%w[escalate])
      md = pack.skills.fetch("escalate")
      expect(md).to match(/\A---\s*\nname: escalate\ndescription: Escalate to a human\n---/)
      expect(md).to include("Hand off when angry.")
    end

    it "data_tool adds a ToolDefinition AND allowlists its name (NF2)" do
      pk = Harness.agent("shop") do
        model "m"
        data_tool("name" => "cart", "description" => "d", "request" => { "url" => "https://api.test" })
      end.to_pack
      expect(pk.tools.map { |t| t["name"] }).to eq(%w[cart])
      expect(pk.config[:tools_allow]).to include("cart")
    end

    it "guardrails(...) stores content-safety config on the pack (RFC-0009, opt-in)" do
      pk = Harness.agent("safe") do
        model "m"
        guardrails input: true, output: true, strictness: "high",
                   responses: { "injection" => "I can't help with that." }
      end.to_pack
      expect(pk.config[:guardrails]).to eq(
        "input" => true, "output" => true, "strictness" => "high",
        "responses" => { "injection" => "I can't help with that." }
      )
    end

    it "guardrails config round-trips through import to Safety::Config" do
      profile = import_and_read(
        Harness.agent("safe") do
          model "m"
          guardrails input: true, output: true, strictness: "high"
        end.to_pack
      )
      cfg = Harness::Safety::Config.from_profile(profile)
      expect(cfg.input).to be(true)
      expect(cfg.output).to be(true)
      expect(cfg.strictness).to eq(:high)
    end

    it "raw SKILL.md content (already has frontmatter) passes through untouched" do
      raw = "---\nname: promo\ndescription: promos\n---\n\nAlways mention the promo."
      pk = Harness.agent("x") { model "m"; skill "promo", raw }.to_pack
      expect(pk.skills.fetch("promo")).to eq(raw)
    end
  end

  # A lean authoring graph over Memory: imports any Pack via the standard
  # PackImporter and reads the profile back — the config-over-code round-trip.
  def import_and_read(pack)
    backend = Harness::Stores::Memory.new
    cs = Harness::ConfigStore.new(store: backend)
    profiles = Harness::StoredProfileSource.new(config_store: cs)
    afs = Harness::AgentFileStore.new(config_store: cs)
    ss = Harness::SkillStore.new(config_store: cs)
    ts = Harness::ToolStore.new(config_store: cs)
    es = Harness::EventStream.new
    reg = Harness::OverlayToolRegistry.new(base: Harness::ToolRegistry.new, tool_store: ts,
                                           http: Harness::HttpClient.new, event_stream: es)
    cat = Harness::ToolCatalog.new(tool_registry: reg)
    skill_cat = Harness::SkillCatalog.new([], store: ss)

    bus = Harness::CommandBus.new
    bus.register(:create_agent, Harness::Commands::CreateAgent.new(profile_source: profiles, event_stream: es))
    bus.register(:update_agent, Harness::Commands::UpdateAgent.new(profile_source: profiles, event_stream: es))
    bus.register(:write_agent_file, Harness::Commands::WriteAgentFile.new(profile_source: profiles, agent_file_store: afs, event_stream: es))
    bus.register(:write_skill, Harness::Commands::WriteSkill.new(skill_store: ss, skill_catalog: skill_cat, event_stream: es))
    bus.register(:write_data_tool, Harness::Commands::WriteDataTool.new(tool_store: ts, registry: reg, tool_catalog: cat, event_stream: es))

    Harness::PackImporter.new(bus: bus, profiles: profiles).import(pack)
    profiles.fetch(pack.config[:id])
  end

  describe "PARITY — DSL profile == hand-written equivalent pack (§13.3 done)" do
    let(:dsl_agent) do
      Harness.agent("bia") do
        model "deepseek-chat"
        provider :deepseek
        instructions "You are Bia."
        tools "menu", "calc"
        skill "escalate", description: "Escalate to a human", instructions: "Hand off when angry."
        memory true
      end
    end

    # The SAME agent authored by hand as a portable pack (what a non-Ruby caller
    # would ship). If these differ, the DSL is not faithfully generating the data.
    let(:hand_pack) do
      Harness::Pack.from_h(
        config: {
          id: "bia", model: "deepseek-chat", provider: "deepseek",
          base_prompt: "You are Bia.", tools_allow: %w[menu calc],
          skills: %w[escalate], memory: true,
          policies: %i[tool_allowlist skill_allowlist]
        },
        skills: {
          "escalate" => "---\nname: escalate\ndescription: Escalate to a human\n---\n\nHand off when angry.\n"
        }
      )
    end

    it "the generated pack round-trips to the SAME profile as the hand pack" do
      from_dsl = import_and_read(dsl_agent.to_pack)
      from_hand = import_and_read(hand_pack)
      expect(from_dsl).to eq(from_hand)
    end

    it "Definition#profile (its own runtime import) matches that profile too" do
      expect(dsl_agent.profile).to eq(import_and_read(hand_pack))
    end
  end

  describe "#reply / #chat (in-process turn — the quickstart's demo)" do
    let(:agent) do
      Harness.agent("assistant") do
        model "gpt"
        provider :deepseek
        instructions "You are helpful."
      end
    end

    # Scripted LLM: stub create_chat on the runtime's own Executor (no gem call).
    def with_scripted_llm(agent, final:, &script)
      chat = FakeChat.new
      chat.final_content = final
      chat.script = script || proc { emit_chunk(final) }
      agent.runtime.graph.executor.define_singleton_method(:create_chat) { |*_a, **_k| chat }
    end

    it "one-shot reply returns the assistant text" do
      with_scripted_llm(agent, final: "Hello there") { emit_chunk("Hello there") }
      expect(agent.reply("hi")).to eq("Hello there")
    end

    it "session reply threads a session (created on first use)" do
      with_scripted_llm(agent, final: "again") { emit_chunk("again") }
      expect(agent.reply("hi", session: "s1")).to eq("again")
      expect(agent.runtime.graph.session_store.find("s1")).not_to be_nil
    end

    it "imports the agent into the runtime's ProfileSource" do
      expect(agent.runtime.graph.profiles.fetch("assistant")).to be_a(Harness::AgentProfile)
    end
  end
end

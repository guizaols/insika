# frozen_string_literal: true

require "spec_helper"
require "insika/tools/run_persona_eval" # the Executor loads it lazily; explicit in the test

# `run_persona_eval` (C3.1): a QA agent's own probe against a sibling agent —
# picks an authored SIMULATED persona case and runs it in-process, scored by
# the configured judge panel. Safety is derived (a target with a reachable
# side-effect tool is refused outright); budget is charged to the CALLING
# agent, never the target.
RSpec.describe Insika::Tools::RunPersonaEval do
  Msg = Struct.new(:content, :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens, keyword_init: true)

  # The chat RubyLLM hands back from `.chat(model:, provider:, ...)`.
  class FakeRawChat
    def initialize(script)
      @script = script
    end

    def with_temperature(_) = self
    def ask(prompt) = @script.call(prompt)
  end

  # Stands in for the graph's own RubyLLM::Context (`runtime.llm`). One script
  # per model, so the persona and the judge get independent, deterministic replies.
  class FakeLLM
    def initialize(scripts) = @scripts = scripts

    def chat(model:, provider:, assume_model_exists:)
      FakeRawChat.new(@scripts.fetch(model))
    end
  end

  # The GraphTransport-compatible `runtime`: answers the target agent's side of
  # the conversation, in-process, no server. `llm` is the seam the tool reads
  # for its OWN persona/judge calls (never the target's turn).
  class FakeGraphRuntime
    attr_reader :calls, :llm

    def initialize(llm, &script)
      @llm = llm
      @script = script
      @calls = []
    end

    def chat(message, session_id:, agent:)
      @calls << { message: message, session_id: session_id, agent: agent }
      text, error = @script.call(message)
      raise Insika::Error, error if error

      text
    end
  end

  class PersonaEvalFakeRegistry
    def initialize(side_effect: [])
      @side = Array(side_effect)
    end

    def names = %w[search_products create_order]
    def side_effect?(name) = @side.include?(name.to_s)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:golden_store) { Insika::GoldenStore.new(config_store: config_store) }
  let(:settings_store) { Insika::SettingsStore.new(config_store: config_store) }
  let(:budget_ledger) { Insika::BudgetLedger.new(store: backend) }
  let(:registry) { PersonaEvalFakeRegistry.new }

  let(:target_profile) { Insika::AgentProfile.build(id: "loja", model: "m", tools_allow: %w[search_products]) }
  let(:qa_profile) { Insika::AgentProfile.build(id: "qa", model: "m") }
  let(:profiles) { Insika::StaticProfileSource.new("loja" => target_profile, "qa" => qa_profile) }

  let(:judge_reply) { '{"score": 0.9, "reason": "handled the discovery well"}' }
  let(:llm) do
    FakeLLM.new(
      "persona-model" => ->(_p) { Msg.new(content: "tá bom, obrigada <<goal_met>>", input_tokens: 10, output_tokens: 5) },
      "judge-model" => lambda { |_p|
        Msg.new(content: judge_reply, input_tokens: 20, output_tokens: 8, cached_tokens: 2, cache_creation_tokens: 0)
      }
    )
  end
  let(:runtime) { FakeGraphRuntime.new(llm) { |_m| ["aqui estão algumas opções reais", nil] } }

  def seed_case(id: "case-1", agent: "loja", tenant: nil)
    golden_store.write(
      { "id" => id, "agent" => agent, "tenant" => tenant,
        "persona" => { "goal" => "achar um presente", "style" => "curto",
                       "opens_with" => "oi, queria um presente",
                       "knows" => { "orcamento" => "100" }, "max_turns" => 5 },
        "expect" => { "policy" => "investigate_first", "rubric" => "descobre o objetivo antes de recomendar",
                     "min_score" => 0.7 } }.compact
    )
  end

  def tool(**overrides)
    described_class.new(
      golden_store: golden_store, profiles: profiles, tool_registry: registry, runtime: runtime,
      settings_store: settings_store, budget_ledger: budget_ledger, **overrides
    )
  end

  def bound(t, agent: "qa", tenant: nil)
    t.turn_context = { agent_id: agent, command_tenant: tenant }
    t
  end

  before do
    settings_store.update("utility_model" => "persona-model",
                          "evals" => { "judges" => [{ "model" => "judge-model", "provider" => nil }] })
  end

  describe "the happy path" do
    it "runs the case in-process against its target agent and returns the judge's verdict" do
      seed_case
      result = bound(tool).execute(case_id: "case-1")

      expect(result[:error]).to be_nil
      expect(result[:case]).to eq("case-1")
      expect(result[:agent]).to eq("loja")
      expect(result[:stop]).to eq("goal_met")
      expect(result[:turns]).to eq(1)
      expect(result[:score]).to eq(0.9)
      expect(result[:pass]).to be(true)
      expect(result[:reason]).to eq("handled the discovery well")
      expect(result[:transcript]).to eq([
                                          { role: "user", text: "oi, queria um presente" },
                                          { role: "assistant", text: "aqui estão algumas opções reais" },
                                          { role: "user", text: "tá bom, obrigada" }
                                        ])
    end

    it "runs the target through a fresh conv every time (never reuses a session)" do
      seed_case
      bound(tool).execute(case_id: "case-1")
      bound(tool).execute(case_id: "case-1")
      convs = runtime.calls.map { |c| c[:session_id] }
      expect(convs.uniq.length).to eq(convs.length)
    end

    it "charges the persona + judge spend to the CALLING agent, never the target" do
      seed_case(tenant: "acme")
      bound(tool, agent: "qa", tenant: "acme").execute(case_id: "case-1")
      # persona: 10 + 5 = 15 · judge: 20 + 8 + 2 (cached) + 0 = 30 · total 45
      expect(budget_ledger.current(tenant: "acme", agent: "qa")[:daily]).to eq(45)
      expect(budget_ledger.current(tenant: "acme", agent: "loja")[:daily]).to eq(0)
    end
  end

  describe "safety — derived, never a flag" do
    it "refuses a target that exposes a reachable side-effect tool, naming it" do
      seed_case
      profile = Insika::AgentProfile.build(id: "loja", model: "m", tools_allow: %w[search_products create_order])
      profiles_with_writer = Insika::StaticProfileSource.new("loja" => profile, "qa" => qa_profile)
      writer_registry = PersonaEvalFakeRegistry.new(side_effect: %w[create_order])

      result = bound(tool(profiles: profiles_with_writer, tool_registry: writer_registry)).execute(case_id: "case-1")
      expect(result[:error]).to match(/side-effect tool.*create_order/)
      expect(runtime.calls).to be_empty # never even started the conversation
    end

    it "runs when the target has no reachable side-effect tool" do
      seed_case
      expect { bound(tool).execute(case_id: "case-1") }.not_to raise_error
      expect(runtime.calls).not_to be_empty
    end
  end

  describe "the enumerated case_id" do
    it "only lists SIMULATED cases, never a scripted (turns:) one" do
      seed_case(id: "case-1")
      golden_store.write({ "id" => "case-2", "agent" => "loja",
                           "turns" => [{ "user" => "oi" }], "expect" => {} })
      schema = bound(tool).params_schema
      enum = schema.dig(:properties, :case_id, :enum) || schema.dig("properties", "case_id", "enum")
      expect(enum).to eq(["case-1"])
    end
  end

  describe "input validation" do
    it "an unknown case id is a clear error, never a raise" do
      expect(bound(tool).execute(case_id: "nope")[:error]).to match(/unknown or invalid/)
    end

    it "a case targeting an unconfigured agent is a clear error" do
      seed_case(agent: "ghost-agent")
      expect(bound(tool).execute(case_id: "case-1")[:error]).to match(/unknown agent/)
    end

    it "refuses with no persona model configured" do
      settings_store.update("utility_model" => nil)
      seed_case
      expect(bound(tool).execute(case_id: "case-1")[:error]).to match(/persona model/)
    end

    it "refuses with no judge configured" do
      bare_settings = Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new))
      bare_settings.update("utility_model" => "persona-model")
      seed_case
      result = bound(tool(settings_store: bare_settings)).execute(case_id: "case-1")
      expect(result[:error]).to match(/no judge configured/)
    end
  end

  describe "tenant isolation (C3.1)" do
    it "the enumerated case_id only lists the CALLING agent's own tenant" do
      seed_case(id: "case-1", tenant: "acme")
      seed_case(id: "case-2", tenant: "other")
      schema = bound(tool, tenant: "acme").params_schema
      enum = schema.dig(:properties, :case_id, :enum) || schema.dig("properties", "case_id", "enum")
      expect(enum).to eq(["case-1"])
    end

    it "a case with no declared tenant belongs to 'platform' (the single-tenant default)" do
      seed_case(id: "case-1")
      schema = bound(tool, tenant: nil).params_schema
      enum = schema.dig(:properties, :case_id, :enum) || schema.dig("properties", "case_id", "enum")
      expect(enum).to eq(["case-1"])
    end

    it "refuses another tenant's case with the SAME wording an unknown id gets (no leak)" do
      seed_case(id: "case-1", tenant: "other")
      not_found = bound(tool, tenant: "acme").execute(case_id: "nope")[:error]
      wrong_tenant = bound(tool, tenant: "acme").execute(case_id: "case-1")[:error]
      # Same template, each echoing only the id the CALLER already typed — never
      # a hint that "case-1" exists, just belongs to somebody else.
      expect(wrong_tenant).to eq("unknown or invalid persona case 'case-1'")
      expect(not_found).to eq("unknown or invalid persona case 'nope'")
      expect(runtime.calls).to be_empty
    end
  end

  describe "budget" do
    it "skips visibly, before spending anything, when the calling agent's hard cap is already spent" do
      seed_case
      capped = Insika::AgentProfile.build(id: "qa", model: "m", budget: { "daily" => 10 })
      budget_ledger.add(tenant: nil, agent: "qa", by: 10)
      profiles_capped = Insika::StaticProfileSource.new("loja" => target_profile, "qa" => capped)

      result = bound(tool(profiles: profiles_capped)).execute(case_id: "case-1")
      expect(result).to eq({ skipped: true, reason: "budget", window: "daily" })
      expect(runtime.calls).to be_empty
    end

    it "a SOFT cap does not skip" do
      seed_case
      soft = Insika::AgentProfile.build(id: "qa", model: "m", budget: { "daily" => 10, "soft" => true })
      budget_ledger.add(tenant: nil, agent: "qa", by: 10)
      profiles_soft = Insika::StaticProfileSource.new("loja" => target_profile, "qa" => soft)

      result = bound(tool(profiles: profiles_soft)).execute(case_id: "case-1")
      expect(result[:skipped]).to be_nil
      expect(runtime.calls).not_to be_empty
    end
  end
end

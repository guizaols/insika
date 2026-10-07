# frozen_string_literal: true

require "spec_helper"

# The platform agent defaults reach the turn: every reader inside the graph
# (commands, executor, loops) gets the profile with them applied.
RSpec.describe Insika::Wiring::Graph do
  it "runs an agent without its own value with the platform's" do
    backend = Insika::Stores::Memory.new
    spine = described_class.spine(backend: backend)
    settings = Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend))
    settings.put_agent_defaults("alerts" => { "webhook" => "https://ops.example/hook" })
    profiles = Insika::StaticProfileSource.new(
      "demo" => Insika::AgentProfile.build(id: "demo", model: "m", provider: :deepseek, tools_allow: [])
    )
    graph = described_class.build(
      spine: spine, profiles: profiles, tool_registry: spine.code_tool_registry,
      tool_catalog: Insika::ToolCatalog.new(tool_registry: spine.code_tool_registry),
      skill_catalog: Insika::SkillCatalog.new([]), prompt_catalog: Insika::PromptCatalog.new([]),
      guardrails: Insika::Safety::Factory.new, context_providers: [],
      executor_extra: { settings_store: settings }
    )
    seen = []
    chat = FakeChat.new
    chat.final_content = "ok"
    chat.script = proc { emit_chunk("ok") }
    graph.executor.define_singleton_method(:create_chat) { |profile, *_a, **_k| seen << profile.alerts; chat }

    Insika::Wiring::GraphChat.new(graph: graph).chat("hi", agent: "demo")

    expect(seen).to eq([{ "webhook" => "https://ops.example/hook" }])
  end
end

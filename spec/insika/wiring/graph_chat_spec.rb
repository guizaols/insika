# frozen_string_literal: true

require "spec_helper"

# GraphChat (C3.1 follow-up): the dispatch+drain seam extracted from
# DSL::Runtime#chat/#run_workflow so a graph built OUTSIDE the DSL —
# config/deployment.rb, the actual production/round1 composition root
# config.ru boots — can hand a #chat-capable `runtime:` to run_persona_eval
# too. dsl_spec.rb already exercises this logic THROUGH the DSL; this spec
# proves the extracted class works standalone, over a plain
# Wiring::Graph.build graph, and that `Graph.register_persona_eval_tool`
# actually wires a WORKING tool on one — the exact gap C3.1 shipped with (the
# tool existed only for DSL-built graphs, never for config/deployment.rb's,
# which round1 and real production both boot through).
RSpec.describe Insika::Wiring::GraphChat do
  Msg = Struct.new(:content, :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens, keyword_init: true)

  class StubbedRawChat
    def initialize(script) = @script = script
    def with_temperature(_) = self
    def ask(prompt) = @script.call(prompt)
  end

  # A bare graph, deliberately NOT the shared Deploy::Wiring singleton
  # (deployment_wiring_spec.rb's own "fresh spine" pattern, for the same
  # reason: a spec must never mutate the one graph the whole suite shares).
  def build_graph(profiles:)
    backend = Insika::Stores::Memory.new
    spine = Insika::Wiring::Graph.spine(backend: backend)
    settings_store = Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend))
    graph = Insika::Wiring::Graph.build(
      spine: spine, profiles: profiles, tool_registry: spine.code_tool_registry,
      tool_catalog: Insika::ToolCatalog.new(tool_registry: spine.code_tool_registry),
      skill_catalog: Insika::SkillCatalog.new([]), prompt_catalog: Insika::PromptCatalog.new([]),
      guardrails: Insika::Safety::Factory.new, context_providers: [],
      executor_extra: { settings_store: settings_store }
    )
    [graph, settings_store]
  end

  def with_scripted_llm(graph, final:)
    chat = FakeChat.new
    chat.final_content = final
    chat.script = proc { emit_chunk(final) }
    graph.executor.define_singleton_method(:create_chat) { |*_a, **_k| chat }
  end

  let(:profile) { Insika::AgentProfile.build(id: "demo", model: "m", provider: :deepseek, tools_allow: []) }
  let(:profiles) { Insika::StaticProfileSource.new("demo" => profile) }

  describe "#chat" do
    it "runs a real in-process turn (dispatch + drain to the terminal event) and returns the text" do
      graph, = build_graph(profiles: profiles)
      with_scripted_llm(graph, final: "hello there")

      text = described_class.new(graph: graph).chat("hi", agent: "demo")
      expect(text).to eq("hello there")
    end

    it "raises Insika::Error for an unknown agent (the command's own rejection, verbatim)" do
      graph, = build_graph(profiles: profiles)
      expect { described_class.new(graph: graph).chat("hi", agent: "ghost") }.to raise_error(Insika::Error)
    end
  end

  describe "Insika::Wiring::Graph.register_persona_eval_tool" do
    it "wires a WORKING run_persona_eval on a plain Graph.build graph, not just a DSL-built one" do
      graph, settings_store = build_graph(profiles: profiles)
      settings_store.update("utility_model" => "persona-model",
                            "evals" => { "judges" => [{ "model" => "judge-model", "provider" => nil }] })
      golden_store = Insika::GoldenStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new))
      golden_store.write(
        { "id" => "case-1", "agent" => "demo",
          "persona" => { "goal" => "achar um presente", "opens_with" => "oi, queria um presente",
                         "knows" => { "orcamento" => "100" }, "max_turns" => 1 },
          "expect" => { "rubric" => "seja cordial" } }
      )
      Insika::Wiring::Graph.register_persona_eval_tool(graph, golden_store: golden_store, settings_store: settings_store)
      with_scripted_llm(graph, final: "aqui estão algumas opções reais")

      raw_chats = {
        "persona-model" => StubbedRawChat.new(->(_p) { Msg.new(content: "<<goal_met>>", input_tokens: 1, output_tokens: 1) }),
        "judge-model" => StubbedRawChat.new(lambda { |_p|
          Msg.new(content: '{"score": 0.9, "reason": "handled it well"}', input_tokens: 2, output_tokens: 2)
        })
      }
      allow(RubyLLM).to receive(:chat) { |model:, provider:, assume_model_exists:| raw_chats.fetch(model) }

      tool = graph.code_tool_registry.entries.find { |e| e.name == "run_persona_eval" }.factory.call
      result = tool.execute(case_id: "case-1")

      expect(result[:error]).to be_nil
      expect(result[:agent]).to eq("demo")
      expect(result[:score]).to eq(0.9)
      expect(result[:pass]).to be(true)
      expect(result[:transcript]).to eq([
                                          { role: "user", text: "oi, queria um presente" },
                                          { role: "assistant", text: "aqui estão algumas opções reais" }
                                        ])
    end
  end
end

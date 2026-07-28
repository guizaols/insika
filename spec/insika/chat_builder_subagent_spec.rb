# frozen_string_literal: true

require "spec_helper"
require "ruby_llm"
require "insika/tools/subagent"  # the Executor loads these lazily in create_chat;
require "insika/tools/subagents" # explicit here

# RFC-0010: the spawn_subagent system tool is wired by the ChatBuilder, gated by
# a runner + a non-empty profile.subagents (the double gate, like `remember`).
RSpec.describe "Insika::ChatBuilder subagent wiring (RFC-0010)" do
  Ctx2 = Struct.new(:system)
  St = Struct.new(:context, :allowed_tools, :allowed_skills, :profile, :task,
                  :current_tool_call, :current_tool_name, keyword_init: true)

  let(:runner) { Class.new { def run_subagent(**) = { text: "x", session_id: "sub-1" } }.new }
  let(:skill_catalog) { instance_double("Insika::SkillCatalog") }
  let(:chat) { FakeChat.new }
  let(:inert) { Object.new }

  def builder(subagent_runner:)
    Insika::ChatBuilder.new(tool_registry: inert, skill_catalog: skill_catalog,
                             checkpoint_store: inert, event_stream: inert,
                             hooks: Insika::Hooks.new, subagent_runner: subagent_runner)
  end

  def state(subagents:)
    profile = Insika::AgentProfile.build(id: "parent", model: "m", subagents: subagents)
    St.new(context: Ctx2.new("SOUL"), allowed_tools: [], allowed_skills: [],
           profile: profile, task: Struct.new(:id, :session_id).new("t", "s"))
  end

  it "wires spawn_subagent AND spawn_subagents when a runner is present AND profile.subagents is non-empty" do
    builder(subagent_runner: runner).configure_chat(chat, state(subagents: ["researcher"]))
    expect(chat.tools.map(&:name)).to include("spawn_subagent", "spawn_subagents")
  end

  it "does NOT wire them when profile.subagents is empty/absent (opt-in)" do
    builder(subagent_runner: runner).configure_chat(chat, state(subagents: nil))
    expect(chat.tools.map(&:name)).not_to include("spawn_subagent", "spawn_subagents")
  end

  it "does NOT wire it when no runner is injected (parity for a builder without delegation)" do
    builder(subagent_runner: nil).configure_chat(chat, state(subagents: ["researcher"]))
    expect(chat.tools.map(&:name)).not_to include("spawn_subagent")
  end

  it "hands the tool the runner (execute delegates to run_subagent)" do
    builder(subagent_runner: runner).configure_chat(chat, state(subagents: ["researcher"]))
    tool = chat.tools.find { |t| t.name == "spawn_subagent" }
    expect(tool.execute(agent: "researcher", message: "hi")).to eq({ text: "x", session_id: "sub-1" })
  end
end

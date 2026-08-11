# frozen_string_literal: true

require "spec_helper"
require "async"
require "tmpdir"
require "fileutils"

# Real providers integration + Builder: proves assembly
# parity with and the sacrifice order under budget (L7).
RSpec.describe "ContextBuilder + real providers" do
  let(:event_stream) { SpyEventStream.new }

  around do |example|
    Dir.mktmpdir { |d| @dir = d; example.run }
  end

  def build(providers, profile, session: nil, checkpoint: nil, budget: 8_000)
    request = Insika::ContextRequest.new(session: session, message: "oi", profile: profile,
                                          tenant: nil, vars: {}, checkpoint: checkpoint)
    builder = Insika::ContextBuilder.new(providers: providers, event_stream: event_stream)
    Sync { builder.call(with_budget(request, budget)) }
  end

  def with_budget(request, budget)
    prof = request.profile.with(limits: request.profile.limits.merge(context_budget: budget))
    request.with(profile: prof)
  end

  def write_skill(name)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: d\n---\nbody\n")
  end

  it "assembles system as Prompt(100) -> Skill(80), joined by \\n\\n (parity)" do
    soul = File.join(@dir, "SOUL.md")
    File.write(soul, "Você é o assistente.")
    write_skill("cardapio")
    catalog = Insika::SkillCatalog.new(@dir)
    profile = Insika::AgentProfile.build(id: "a", model: "m", base_prompt: "", skills: nil)
    providers = [
      Insika::Context::Providers::Prompt.new(base: "Base.", files: [soul]),
      Insika::Context::Providers::Skill.new(catalog: catalog)
    ]

    pkg = build(providers, profile)

    skills_block = catalog.format_for_prompt(catalog.effective(nil))
    expected = "Base.\n\nVocê é o assistente.\n\n#{skills_block}"
    expect(pkg.system).to eq(expected)
  end

  # Regression: `profile.base_prompt` (what the DSL's `instructions` and a pack
  # manifest set) reached the STORE and the A2A agent card but never the model —
  # every composition root wires `base: ""`, so an agent whose identity was inline
  # ran with no identity at all. It hid because a chatty model still answers
  # plausibly; it was caught by asking a live provider to reply "BANANA" and
  # getting the capital of France.
  it "injects the agent's own base_prompt into the system prompt" do
    profile = Insika::AgentProfile.build(id: "a", model: "m", base_prompt: "You are Bia.", skills: [])

    pkg = build([Insika::Context::Providers::Prompt.new(base: "")], profile)

    expect(pkg.system).to eq("You are Bia.")
  end

  it "keeps base_prompt ADDITIVE to the wiring base and the agent's prompt files" do
    identity = File.join(@dir, "IDENTITY.md")
    File.write(identity, "Never promise a delivery date.")
    profile = Insika::AgentProfile.build(id: "a", model: "m", base_prompt: "You are Bia.",
                                          prompt_files: [identity], skills: [])

    pkg = build([Insika::Context::Providers::Prompt.new(base: "Platform preamble.")], profile)

    expect(pkg.system).to eq("Platform preamble.\n\nYou are Bia.\n\nNever promise a delivery date.")
  end

  it "under tight budget: old history evicted first; skills and identity intact (L7)" do
    write_skill("cardapio")
    catalog = Insika::SkillCatalog.new(@dir)
    profile = Insika::AgentProfile.build(id: "a", model: "m", base_prompt: "IDENTIDADE", skills: nil)
    session_store = Insika::SessionStore.new(store: Insika::Stores::Memory.new)
    session_store.create(id: "s1")
    # 6 history messages of controlled size (~44 chars -> 11 tokens each).
    # The Hash {role:, content:} adds a few tokens; we keep some margin in the budget.
    6.times { |i| session_store.append_messages("s1", { role: "user", content: "num#{i}-#{'.' * 40}" }) }
    providers = [
      Insika::Context::Providers::Prompt.new(base: "IDENTIDADE"),
      Insika::Context::Providers::Skill.new(catalog: catalog),
      Insika::Context::Providers::Session.new(session_store: session_store)
    ]

    # budget that keeps identity (pinned) + skills (80) + SOME histories
    # (the most recent), cutting the oldest. Chosen so that >0 and <6 survive.
    pkg = build(providers, profile, session: session_store.find("s1"), budget: 90)

    survived = pkg.history.map { |m| m[:content] }
    # identity (pinned) and skills (80 > history) always survive
    expect(pkg.system).to include("IDENTIDADE", "cardapio")
    # cut part, but not all: proves the sacrifice order
    expect(pkg.budget[:evicted]).not_to be_empty
    expect(survived.size).to be_between(1, 5)
    # what survived are the MOST RECENT; the oldest (num0) was dropped first
    expect(survived).to include(a_string_including("num5"))
    expect(survived).not_to include(a_string_including("num0"))
  end
end

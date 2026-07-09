# frozen_string_literal: true

require "spec_helper"
require "async"
require "tmpdir"
require "fileutils"

# Integração providers reais (task 15) + Builder (task 14): prova a paridade de
# montagem com a Fase 0 (doc 04 §3) e a ordem de sacrifício sob orçamento (L7).
RSpec.describe "ContextBuilder + providers reais" do
  let(:event_stream) { SpyEventStream.new }

  around do |example|
    Dir.mktmpdir { |d| @dir = d; example.run }
  end

  def build(providers, profile, session: nil, checkpoint: nil, budget: 8_000)
    request = Harness::ContextRequest.new(session: session, message: "oi", profile: profile,
                                          tenant: nil, vars: {}, checkpoint: checkpoint)
    builder = Harness::ContextBuilder.new(providers: providers, event_stream: event_stream)
    Sync { builder.call(with_budget(request, budget)) }
  end

  def with_budget(request, budget)
    prof = request.profile.with(limits: request.profile.limits.merge(context_budget: budget))
    request.with(profile: prof)
  end

  def write_skill(name)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: d\n---\ncorpo\n")
  end

  it "monta system como Prompt(100) -> Skill(80), unidos por \\n\\n (paridade Fase 0)" do
    soul = File.join(@dir, "SOUL.md")
    File.write(soul, "Você é o assistente.")
    write_skill("cardapio")
    catalog = Harness::SkillCatalog.new(@dir)
    profile = Harness::AgentProfile.build(id: "a", model: "m", base_prompt: "", skills: nil)
    providers = [
      Harness::Context::Providers::Prompt.new(base: "Base.", files: [soul]),
      Harness::Context::Providers::Skill.new(catalog: catalog)
    ]

    pkg = build(providers, profile)

    skills_block = catalog.format_for_prompt(catalog.effective(nil))
    expected = "Base.\n\nVocê é o assistente.\n\n#{skills_block}"
    expect(pkg.system).to eq(expected)
  end

  it "sob orçamento apertado: histórico antigo evictado primeiro; skills e identidade intactos (L7)" do
    write_skill("cardapio")
    catalog = Harness::SkillCatalog.new(@dir)
    profile = Harness::AgentProfile.build(id: "a", model: "m", base_prompt: "IDENTIDADE", skills: nil)
    session_store = Harness::SessionStore.new(store: Harness::Stores::Memory.new)
    session_store.create(id: "s1")
    # 6 mensagens de histórico de tamanho controlado (~44 chars -> 11 tokens cada).
    # O Hash {role:, content:} adiciona uns tokens; usamos margem no orçamento.
    6.times { |i| session_store.append_messages("s1", { role: "user", content: "num#{i}-#{'.' * 40}" }) }
    providers = [
      Harness::Context::Providers::Prompt.new(base: "IDENTIDADE"),
      Harness::Context::Providers::Skill.new(catalog: catalog),
      Harness::Context::Providers::Session.new(session_store: session_store)
    ]

    # orçamento que mantém identidade (pinned) + skills (80) + ALGUMAS histories
    # (as mais recentes), cortando as mais antigas. Escolhido para sobrar >0 e <6.
    pkg = build(providers, profile, session: session_store.find("s1"), budget: 90)

    survived = pkg.history.map { |m| m[:content] }
    # identidade (pinned) e skills (80 > history) sobrevivem sempre
    expect(pkg.system).to include("IDENTIDADE", "cardapio")
    # cortou parte, mas não tudo: prova a ordem de sacrifício
    expect(pkg.budget[:evicted]).not_to be_empty
    expect(survived.size).to be_between(1, 5)
    # o que sobrou são as MAIS RECENTES; a mais antiga (num0) caiu primeiro
    expect(survived).to include(a_string_including("num5"))
    expect(survived).not_to include(a_string_including("num0"))
  end
end

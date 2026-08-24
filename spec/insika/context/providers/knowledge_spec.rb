# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::Knowledge do
  let(:backend) { Insika::Stores::Memory.new }
  let(:store) { Insika::KnowledgeStore.new(store: backend) }

  def request(knowledge:, message: "qual o prazo pro CEP de Campinas?", tenant: nil)
    profile = Insika::AgentProfile.build(id: "acme", model: "m", knowledge: knowledge)
    Insika::ContextRequest.new(session: nil, message: message, profile: profile,
                              tenant: tenant, vars: {}, checkpoint: nil)
  end

  def seed(name, description:, body:, confidence: 0.6, links: [])
    full_body = links.empty? ? body : "#{body} #{links.map { |l| "[[#{l}]]" }.join(' ')}"
    store.write("acme", name,
                Insika::Knowledge::Concept.render(
                  name: name, description: description, type: "fact", body: full_body,
                  provenance: "observed", confidence: confidence, sources: ["sess_1"], occurrences: 1,
                  created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601
                ))
  end

  it "retrieve off (enabled_for? false) -> produces nothing" do
    provider = described_class.new(store: store)
    expect(provider.enabled_for?(request(knowledge: nil).profile)).to be(false)
    expect(provider.enabled_for?(request(knowledge: { "extract" => true }).profile)).to be(false)
  end

  it "retrieve on: enabled_for? true" do
    provider = described_class.new(store: store)
    expect(provider.enabled_for?(request(knowledge: { "retrieve" => true }).profile)).to be(true)
  end

  it "no match -> no fragment" do
    seed("cep-13-campinas", description: "d", body: "b")
    frags = described_class.new(store: store).call(request(knowledge: { "retrieve" => true },
                                                            message: "totally unrelated"))
    expect(frags).to eq([])
  end

  it "a match injects a level-1 <knowledge> block at priority KNOWLEDGE, non-pinned" do
    seed("cep-13-campinas", description: "CEPs 13xxx ship from Campinas", body: "the full body, not injected")
    frags = described_class.new(store: store).call(request(knowledge: { "retrieve" => true }))

    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.priority, f.pinned]).to eq([:system, Insika::Context::Priority::KNOWLEDGE, false])
    expect(f.content).to include("<knowledge>", 'name="cep-13-campinas"', 'confidence="0.60"',
                                 'provenance="observed"', "CEPs 13xxx ship from Campinas")
    expect(f.content).to include("load_knowledge")
    expect(f.content).not_to include("the full body, not injected") # level 1 only — description, never body
  end

  it "labels carry name and reason for the audit trail" do
    seed("cep-13-campinas", description: "d", body: "b")
    frags = described_class.new(store: store).call(request(knowledge: { "retrieve" => true }))
    expect(frags.first.labels).to eq([{ "name" => "cep-13-campinas", "reason" => "top-K match" }])
  end

  it "expands one hop through [[links]] of the matched concepts, capped at top_k again" do
    seed("cep-13-campinas", description: "d", body: "b", links: ["frete-gratis"])
    seed("frete-gratis", description: "free shipping over R$199", body: "b2")
    frags = described_class.new(store: store).call(
      request(knowledge: { "retrieve" => true, "top_k" => 5 })
    )
    names = frags.first.labels.map { |l| l["name"] }
    expect(names).to contain_exactly("cep-13-campinas", "frete-gratis")
    reasons = frags.first.labels.to_h { |l| [l["name"], l["reason"]] }
    expect(reasons["frete-gratis"]).to eq("one-hop link")
    expect(frags.first.content).to include("free shipping over R$199")
  end

  it "does not expand a link that does not resolve to a stored concept" do
    seed("cep-13-campinas", description: "d", body: "b", links: ["ghost-concept"])
    frags = described_class.new(store: store).call(request(knowledge: { "retrieve" => true }))
    expect(frags.first.labels.map { |l| l["name"] }).to eq(["cep-13-campinas"])
  end

  it "does not re-add a linked concept that is already a top-K match" do
    seed("cep-13-campinas", description: "d", body: "b", links: ["frete-gratis"])
    seed("frete-gratis", description: "d frete campinas", body: "campinas") # also matches directly
    frags = described_class.new(store: store).call(request(knowledge: { "retrieve" => true }))
    names = frags.first.labels.map { |l| l["name"] }
    expect(names.count("frete-gratis")).to eq(1)
  end

  it "respects the configured top_k" do
    5.times { |i| seed("c-#{i}", description: "d", body: "campinas #{i}") }
    frags = described_class.new(store: store).call(
      request(knowledge: { "retrieve" => true, "top_k" => 2 }, message: "campinas")
    )
    expect(frags.first.labels.size).to eq(2)
  end

  it "scopes by tenant" do
    store.write("acme", "loja-a-only",
                Insika::Knowledge::Concept.render(
                  name: "loja-a-only", description: "d", type: "fact", body: "campinas loja a",
                  provenance: "observed", confidence: 0.6, sources: [], occurrences: 1,
                  created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601
                ), tenant: "loja-a")
    default_scope = described_class.new(store: store).call(
      request(knowledge: { "retrieve" => true }, message: "campinas")
    )
    expect(default_scope).to eq([])

    tenant_scope = described_class.new(store: store).call(
      request(knowledge: { "retrieve" => true }, message: "campinas", tenant: "loja-a")
    )
    expect(tenant_scope.first.labels.map { |l| l["name"] }).to eq(["loja-a-only"])
  end
end

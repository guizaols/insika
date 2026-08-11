# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::Request do
  let(:profile) { Insika::AgentProfile.build(id: "a", model: "m") }

  def request(tenant: nil, vars: {})
    Insika::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                tenant: tenant, vars: vars, checkpoint: nil)
  end

  it "produces 1 :system priority 40 fragment with tenant and vars" do
    frags = described_class.new.call(request(tenant: "acme", vars: { plan: "pro" }))

    expect(frags.size).to eq(1)
    f = frags.first
    expect(f.placement).to eq(:system)
    expect(f.priority).to eq(40)
    expect(f.content).to include("tenant: acme", "plan: pro")
  end

  it "produces no fragment without metadata (tenant nil, empty vars)" do
    expect(described_class.new.call(request)).to eq([])
  end

  it "is deterministic (same input -> same content)" do
    req = request(tenant: "acme", vars: { a: 1, b: 2 })
    a = described_class.new.call(req).first.content
    b = described_class.new.call(req).first.content
    expect(a).to eq(b)
  end

  it "is not required (metadata degrades)" do
    expect(described_class.new.required?).to be(false)
  end

  it "never renders '__'-prefixed internal vars (e.g. the model pin __llm__)" do
    vars = { "plan" => "pro", Insika::ModelResolver::SESSION_SLOT => { "model" => "secret-m" } }
    content = described_class.new.call(request(tenant: "acme", vars: vars)).first.content
    expect(content).to include("plan: pro")
    expect(content).not_to include("__llm__")
    expect(content).not_to include("secret-m")
  end
end

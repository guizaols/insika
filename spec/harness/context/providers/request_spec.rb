# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Context::Providers::Request do
  let(:profile) { Harness::AgentProfile.build(id: "a", model: "m") }

  def request(tenant: nil, vars: {})
    Harness::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                tenant: tenant, vars: vars, checkpoint: nil)
  end

  it "produz 1 fragmento :system priority 40 com tenant e vars" do
    frags = described_class.new.call(request(tenant: "acme", vars: { plan: "pro" }))

    expect(frags.size).to eq(1)
    f = frags.first
    expect(f.placement).to eq(:system)
    expect(f.priority).to eq(40)
    expect(f.content).to include("tenant: acme", "plan: pro")
  end

  it "não produz fragmento sem metadados (tenant nil, vars vazio)" do
    expect(described_class.new.call(request)).to eq([])
  end

  it "é determinístico (mesma entrada -> mesmo content)" do
    req = request(tenant: "acme", vars: { a: 1, b: 2 })
    a = described_class.new.call(req).first.content
    b = described_class.new.call(req).first.content
    expect(a).to eq(b)
  end

  it "não é required (metadados degradam)" do
    expect(described_class.new.required?).to be(false)
  end
end

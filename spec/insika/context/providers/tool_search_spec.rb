# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::ToolSearch do
  FakeTool = Struct.new(:description)

  let(:registry) do
    reg = Insika::ToolRegistry.new
    reg.register("send_email") { FakeTool.new("Sends an e-mail") }
    reg.register("create_invoice") { FakeTool.new("Generates invoice") }
    reg
  end
  let(:catalog) { Insika::ToolCatalog.new(tool_registry: registry) }

  def request(tools_deferred:)
    profile = Insika::AgentProfile.build(id: "a", model: "m", tools_deferred: tools_deferred)
    Insika::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                tenant: nil, vars: {}, checkpoint: nil)
  end

  it "produces 1 :system priority 70 non-pinned fragment == format_for_prompt(subset)" do
    frags = described_class.new(catalog: catalog).call(request(tools_deferred: %w[send_email create_invoice]))

    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.priority, f.pinned]).to eq([:system, 70, false])
    expect(f.content).to eq(catalog.format_for_prompt(catalog.subset(%w[send_email create_invoice])))
    expect(f.content).to include("send_email", "create_invoice")
  end

  it "only the deferred tools appear (sliced via subset)" do
    frag = described_class.new(catalog: catalog).call(request(tools_deferred: ["send_email"])).first
    expect(frag.content).to include("send_email")
    expect(frag.content).not_to include("create_invoice")
  end

  it "tools_deferred nil -> no fragment (parity)" do
    expect(described_class.new(catalog: catalog).call(request(tools_deferred: nil))).to eq([])
  end

  it "tools_deferred [] -> no fragment" do
    expect(described_class.new(catalog: catalog).call(request(tools_deferred: []))).to eq([])
  end
end

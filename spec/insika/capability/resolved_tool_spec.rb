# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Capability::ResolvedTool do
  # Fake tool (same spirit as ChargeTool in tool_envelope_approval_spec).
  class FakeBrowseTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "puppeteer_browser"
    def description = "abre uma página"
    def execute(url:) = (@calls << url) && "ok:#{url}"
    def call(args) = execute(**args)
  end

  let(:impl) { FakeBrowseTool.new }
  subject(:resolved) do
    described_class.new(impl, capability_name: "browse", impl_name: "puppeteer_browser")
  end

  it "exposes name = the capability name (not the impl's)" do
    expect(resolved.name).to eq("browse")
  end

  it "exposes impl_name = the concrete name" do
    expect(resolved.impl_name).to eq("puppeteer_browser")
  end

  it "delegates execute to the impl with args intact" do
    expect(resolved.execute(url: "x")).to eq("ok:x")
    expect(impl.calls).to eq(["x"])
  end

  it "delegates description and call to the impl unchanged" do
    expect(resolved.description).to eq("abre uma página")
    expect(resolved.call({ url: "y" })).to eq("ok:y")
  end

  it "impl nil: delegated call raises SimpleDelegator error (no hidden guard)" do
    broken = described_class.new(nil, capability_name: "browse", impl_name: "x")
    expect { broken.description }.to raise_error(NoMethodError)
    # name/impl_name belong to the decorator, they don't delegate
    expect(broken.name).to eq("browse")
    expect(broken.impl_name).to eq("x")
  end
end

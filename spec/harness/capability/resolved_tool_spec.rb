# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Capability::ResolvedTool do
  # Fake tool (mesmo espírito do ChargeTool em tool_envelope_approval_spec).
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

  it "expõe name = nome da capability (não o do impl)" do
    expect(resolved.name).to eq("browse")
  end

  it "expõe impl_name = nome concreto" do
    expect(resolved.impl_name).to eq("puppeteer_browser")
  end

  it "delega execute ao impl com args intactos" do
    expect(resolved.execute(url: "x")).to eq("ok:x")
    expect(impl.calls).to eq(["x"])
  end

  it "delega description e call ao impl sem alteração" do
    expect(resolved.description).to eq("abre uma página")
    expect(resolved.call({ url: "y" })).to eq("ok:y")
  end

  it "impl nil: chamada delegada levanta erro do SimpleDelegator (sem guard escondido)" do
    broken = described_class.new(nil, capability_name: "browse", impl_name: "x")
    expect { broken.description }.to raise_error(NoMethodError)
    # name/impl_name são próprios do decorator, não delegam
    expect(broken.name).to eq("browse")
    expect(broken.impl_name).to eq("x")
  end
end

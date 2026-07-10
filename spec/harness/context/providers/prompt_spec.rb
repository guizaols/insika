# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Harness::Context::Providers::Prompt do
  # Algoritmo do SystemPrompt#build da Fase 0 (portado como referência, SEM
  # skills_block) — alvo da caracterização byte-a-byte (doc 04 §7/§8).
  def phase0_build(base, files)
    parts = [base]
    files.each { |f| parts << File.read(f, encoding: "UTF-8") if File.exist?(f) }
    parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
  end

  def profile(prompt_refs: nil)
    Harness::AgentProfile.build(id: "a", model: "m", prompt_refs: prompt_refs)
  end

  def request(prof = profile)
    Harness::ContextRequest.new(session: nil, message: "oi", profile: prof,
                                tenant: nil, vars: {}, checkpoint: nil)
  end

  around do |example|
    Dir.mktmpdir { |d| @dir = d; example.run }
  end

  it "caracterização vs Fase 0: content byte-a-byte igual (base + arquivos, um inexistente)" do
    soul = File.join(@dir, "SOUL.md")
    File.write(soul, "Você é o assistente.")
    missing = File.join(@dir, "missing.md")
    files = [soul, missing]
    base = "Instruções base."

    frag = described_class.new(base: base, files: files).call(request).first

    expect(frag.content).to eq(phase0_build(base, files))
    expect(frag.content).to eq("Instruções base.\n\nVocê é o assistente.")
  end

  it "identidade = 1 fragmento :system priority 100 pinned" do
    frag = described_class.new(base: "id").call(request).first

    expect(frag.placement).to eq(:system)
    expect(frag.priority).to eq(100)
    expect(frag.pinned).to be(true)
  end

  it "identidade vazia -> nenhum fragmento de identidade" do
    expect(described_class.new(base: "", files: []).call(request)).to eq([])
  end

  it "required? == true" do
    expect(described_class.new(base: "x").required?).to be(true)
  end

  describe "prompt_refs" do
    let(:entry) { Struct.new(:body) }
    let(:catalog) do
      double("PromptCatalog").tap do |c|
        allow(c).to receive(:find) { |name| { "a" => entry.new("BODY_A"), "b" => entry.new("BODY_B") }[name] }
      end
    end

    it "resolve refs em fragmentos priority 90 pinned, na ordem do perfil" do
      frags = described_class.new(base: "id", catalog: catalog).call(request(profile(prompt_refs: %w[a b])))

      refs = frags.select { |f| f.priority == 90 }
      expect(refs.map(&:content)).to eq(%w[BODY_A BODY_B])
      expect(refs).to all(have_attributes(pinned: true, placement: :system))
    end

    it "ref inexistente -> ContextError" do
      expect { described_class.new(base: "id", catalog: catalog).call(request(profile(prompt_refs: ["x"]))) }
        .to raise_error(Harness::ContextError)
    end

    it "refs presentes com catalog nil -> ContextError" do
      expect { described_class.new(base: "id", catalog: nil).call(request(profile(prompt_refs: ["a"]))) }
        .to raise_error(Harness::ContextError)
    end

    it "perfil sem refs -> só a identidade" do
      frags = described_class.new(base: "id", catalog: catalog).call(request(profile(prompt_refs: [])))
      expect(frags.size).to eq(1)
      expect(frags.first.priority).to eq(100)
    end
  end
end

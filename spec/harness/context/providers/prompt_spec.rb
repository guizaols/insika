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

  def profile(prompt_refs: nil, prompt_files: [], id: "a")
    Harness::AgentProfile.build(id: id, model: "m", prompt_refs: prompt_refs, prompt_files: prompt_files)
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

  # Etapa C (Fase 4): identidade POR-AGENTE. profile.prompt_files vence sobre os
  # files do wiring; o conteúdo vem do AgentFileStore (ou de disco, compat).
  describe "identidade por-agente (Etapa C)" do
    let(:agent_files) do
      Harness::AgentFileStore.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new))
    end

    it "sem prompt_files: usa os files do wiring (paridade Fase 0 — não regride)" do
      soul = File.join(@dir, "SOUL.md")
      File.write(soul, "Identidade default do deployment.")
      provider = described_class.new(base: "base", files: [soul], agent_files: agent_files)

      frag = provider.call(request(profile(prompt_files: []))).first
      expect(frag.content).to eq("base\n\nIdentidade default do deployment.")
    end

    it "com prompt_files: lê o conteúdo do agente no Store, NÃO os files do wiring" do
      wiring_soul = File.join(@dir, "SOUL.md")
      File.write(wiring_soul, "IDENTIDADE DA BIA")             # default do wiring
      agent_files.write("chef", "IDENTITY.md", "Sou o Chef, especialista em massas.")
      provider = described_class.new(base: "", files: [wiring_soul], agent_files: agent_files)

      frag = provider.call(request(profile(id: "chef", prompt_files: %w[IDENTITY.md]))).first
      expect(frag.content).to eq("Sou o Chef, especialista em massas.")   # própria, não a da Bia
      expect(frag.content).not_to include("IDENTIDADE DA BIA")
    end

    it "concatena vários prompt_files do agente na ordem declarada" do
      agent_files.write("chef", "IDENTITY.md", "IDENT")
      agent_files.write("chef", "SOUL.md", "ALMA")
      provider = described_class.new(base: "B", agent_files: agent_files)

      frag = provider.call(request(profile(id: "chef", prompt_files: %w[IDENTITY.md SOUL.md]))).first
      expect(frag.content).to eq("B\n\nIDENT\n\nALMA")
    end

    it "prompt_files como caminho de disco: fallback a File.read (compat/seed)" do
      disk = File.join(@dir, "IDENTITY.md")
      File.write(disk, "do disco")
      provider = described_class.new(base: "", agent_files: agent_files)

      frag = provider.call(request(profile(id: "chef", prompt_files: [disk]))).first
      expect(frag.content).to eq("do disco")
    end
  end
end

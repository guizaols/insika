# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Insika::Context::Providers::Prompt do
  # SystemPrompt#build algorithm from (ported as reference, WITHOUT
  # skills_block) — target of the byte-for-byte characterization.
  def phase0_build(base, files)
    parts = [base]
    files.each { |f| parts << File.read(f, encoding: "UTF-8") if File.exist?(f) }
    parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
  end

  def profile(prompt_refs: nil, prompt_files: [], id: "a", tool_persistence: nil)
    Insika::AgentProfile.build(id: id, model: "m", prompt_refs: prompt_refs,
                               prompt_files: prompt_files, tool_persistence: tool_persistence)
  end

  # The engine's Tool discipline block rides after every non-empty identity
  # (the deliberate parity break — see TOOL_PERSISTENCE).
  def with_discipline(identity)
    "#{identity}\n\n#{described_class::TOOL_PERSISTENCE}"
  end

  def request(prof = profile)
    Insika::ContextRequest.new(session: nil, message: "oi", profile: prof,
                                tenant: nil, vars: {}, checkpoint: nil)
  end

  around do |example|
    Dir.mktmpdir { |d| @dir = d; example.run }
  end

  it "characterization vs: the base+files concatenation, plus the engine discipline block" do
    soul = File.join(@dir, "SOUL.md")
    File.write(soul, "Você é o assistente.")
    missing = File.join(@dir, "missing.md")
    files = [soul, missing]
    base = "Instruções base."

    frag = described_class.new(base: base, files: files).call(request).first

    expect(frag.content).to eq(with_discipline(phase0_build(base, files)))
    expect(frag.content).to eq(with_discipline("Instruções base.\n\nVocê é o assistente."))
  end

  describe "tool persistence (the engine's Tool discipline block)" do
    it "rides after the identity by default (nil profile flag = ON)" do
      frag = described_class.new(base: "id").call(request).first
      expect(frag.content).to eq(with_discipline("id"))
      expect(frag.content).to include("## Tool discipline")
    end

    it "tool_persistence: false removes the block — identity byte-identical to phase0" do
      frag = described_class.new(base: "id").call(request(profile(tool_persistence: false))).first
      expect(frag.content).to eq("id")
    end

    it "never substitutes an empty identity (no discipline-only fragment)" do
      expect(described_class.new(base: "", files: []).call(request)).to eq([])
    end

    it "a profile stub without the flag reads ON (defensive respond_to?)" do
      stub = Struct.new(:base_prompt, :prompt_files, :prompt_refs).new("", [], [])
      req = Insika::ContextRequest.new(session: nil, message: "oi", profile: stub,
                                       tenant: nil, vars: {}, checkpoint: nil)
      frag = described_class.new(base: "id").call(req).first
      expect(frag.content).to eq(with_discipline("id"))
    end
  end

  it "identity = 1 :system priority 100 pinned fragment" do
    frag = described_class.new(base: "id").call(request).first

    expect(frag.placement).to eq(:system)
    expect(frag.priority).to eq(100)
    expect(frag.pinned).to be(true)
  end

  it "empty identity -> no identity fragment" do
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

    it "resolves refs into priority 90 pinned fragments, in profile order" do
      frags = described_class.new(base: "id", catalog: catalog).call(request(profile(prompt_refs: %w[a b])))

      refs = frags.select { |f| f.priority == 90 }
      expect(refs.map(&:content)).to eq(%w[BODY_A BODY_B])
      expect(refs).to all(have_attributes(pinned: true, placement: :system))
    end

    it "nonexistent ref -> ContextError" do
      expect { described_class.new(base: "id", catalog: catalog).call(request(profile(prompt_refs: ["x"]))) }
        .to raise_error(Insika::ContextError)
    end

    it "refs present with nil catalog -> ContextError" do
      expect { described_class.new(base: "id", catalog: nil).call(request(profile(prompt_refs: ["a"]))) }
        .to raise_error(Insika::ContextError)
    end

    it "profile without refs -> only the identity" do
      frags = described_class.new(base: "id", catalog: catalog).call(request(profile(prompt_refs: [])))
      expect(frags.size).to eq(1)
      expect(frags.first.priority).to eq(100)
    end
  end

  # PER-AGENT identity. profile.prompt_files wins over the
  # wiring files; the content comes from the AgentFileStore (or from disk, compat).
  describe "per-agent identity" do
    let(:agent_files) do
      Insika::AgentFileStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new))
    end

    it "without prompt_files: uses the wiring files (parity — no regression)" do
      soul = File.join(@dir, "SOUL.md")
      File.write(soul, "Identidade default do deployment.")
      provider = described_class.new(base: "base", files: [soul], agent_files: agent_files)

      frag = provider.call(request(profile(prompt_files: []))).first
      expect(frag.content).to eq(with_discipline("base\n\nIdentidade default do deployment."))
    end

    it "with prompt_files: reads the agent's content from the Store, NOT the wiring files" do
      wiring_soul = File.join(@dir, "SOUL.md")
      File.write(wiring_soul, "IDENTIDADE DA BIA")             # wiring default
      agent_files.write("chef", "IDENTITY.md", "Sou o Chef, especialista em massas.")
      provider = described_class.new(base: "", files: [wiring_soul], agent_files: agent_files)

      frag = provider.call(request(profile(id: "chef", prompt_files: %w[IDENTITY.md]))).first
      expect(frag.content).to eq(with_discipline("Sou o Chef, especialista em massas.")) # its own, not Bia's
      expect(frag.content).not_to include("IDENTIDADE DA BIA")
    end

    it "concatenates multiple agent prompt_files in the declared order" do
      agent_files.write("chef", "IDENTITY.md", "IDENT")
      agent_files.write("chef", "SOUL.md", "ALMA")
      provider = described_class.new(base: "B", agent_files: agent_files)

      frag = provider.call(request(profile(id: "chef", prompt_files: %w[IDENTITY.md SOUL.md]))).first
      expect(frag.content).to eq(with_discipline("B\n\nIDENT\n\nALMA"))
    end

    it "prompt_files as a disk path: falls back to File.read (compat/seed)" do
      disk = File.join(@dir, "IDENTITY.md")
      File.write(disk, "do disco")
      provider = described_class.new(base: "", agent_files: agent_files)

      frag = provider.call(request(profile(id: "chef", prompt_files: [disk]))).first
      expect(frag.content).to eq(with_discipline("do disco"))
    end
  end
end

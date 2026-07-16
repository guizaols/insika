# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Fase 6/D4/F6 — o value object Pack: forma portátil de um agente (manifesto +
# arquivos + skills + tools). from_h (wire JSON) e from_dir (disco, docs/prompt-base/06).
RSpec.describe Harness::Pack do
  describe ".from_h" do
    it "normaliza config (symbol), files/skills (string keys) e tools (array)" do
      pack = described_class.from_h(
        "config" => { "id" => "loja", "model" => "m" },
        "files" => { "IDENTITY.md" => "quem sou" },
        "skills" => { "escala" => "---\nname: escala\n---\n" },
        "tools" => [{ "name" => "cart" }]
      )
      expect(pack.config).to eq(id: "loja", model: "m")
      expect(pack.files).to eq("IDENTITY.md" => "quem sou")
      expect(pack.skills).to eq("escala" => "---\nname: escala\n---\n")
      expect(pack.tools).to eq([{ "name" => "cart" }])
    end

    it "tolera chaves symbol no topo (parse simbolizado)" do
      pack = described_class.from_h(config: { id: "x", model: "m" }, files: { "A.md" => "a" })
      expect(pack.config).to eq(id: "x", model: "m")
      expect(pack.files).to eq("A.md" => "a")
    end

    it "campos ausentes -> vazios (nil-safe)" do
      pack = described_class.from_h(nil)
      expect([pack.config, pack.files, pack.skills, pack.tools]).to eq([{}, {}, {}, []])
    end
  end

  describe ".from_dir" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    def write(rel, content)
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    it "lê agent.config.json + *.md da raiz + skills/*/SKILL.md + tools/*.json" do
      write("agent.config.json", JSON.generate(id: "loja-7", model: "deepseek-chat", metadata: { store_id: "7" }))
      write("IDENTITY.md", "quem sou")
      write("SOUL.md", "voz")
      write("skills/escalation/SKILL.md", "---\nname: escalation\n---\ncorpo")
      write("skills/promo/SKILL.md", "---\nname: promo\n---\ncorpo")
      write("tools/cart.json", JSON.generate(name: "cart", description: "d", request: { url: "https://a.test" }))

      pack = described_class.from_dir(@dir)

      expect(pack.config).to include(id: "loja-7", model: "deepseek-chat")
      expect(pack.files.keys).to contain_exactly("IDENTITY.md", "SOUL.md")
      expect(pack.files["IDENTITY.md"]).to eq("quem sou")
      expect(pack.skills.keys).to contain_exactly("escalation", "promo")
      expect(pack.skills["escalation"]).to include("name: escalation")
      expect(pack.tools).to eq([{ "name" => "cart", "description" => "d", "request" => { "url" => "https://a.test" } }])
    end

    it "não desce em skills/ ao coletar os .md da raiz" do
      write("agent.config.json", JSON.generate(id: "a", model: "m"))
      write("AGENTS.md", "fluxo")
      write("skills/x/SKILL.md", "---\nname: x\n---\n")
      pack = described_class.from_dir(@dir)
      expect(pack.files.keys).to eq(["AGENTS.md"]) # SKILL.md não entra em files
    end

    it "sem agent.config.json -> ValidationError" do
      write("IDENTITY.md", "x")
      expect { described_class.from_dir(@dir) }.to raise_error(Harness::ValidationError, /agent\.config\.json/)
    end

    it "pack só com o manifesto (sem md/skills/tools) -> coleções vazias" do
      write("agent.config.json", JSON.generate(id: "a", model: "m"))
      pack = described_class.from_dir(@dir)
      expect([pack.files, pack.skills, pack.tools]).to eq([{}, {}, []])
    end
  end
end

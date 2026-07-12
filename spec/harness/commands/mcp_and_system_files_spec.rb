# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa G (tasks 18-19): instâncias MCP (config durável, credenciais
# mascaradas) + arquivos de sistema globais (injetados em todo agente pelo
# Prompt provider). Roda SEM chave/gem — stores puros sobre o backend Memory.
RSpec.describe "MCP + system-files (Fase 4 Etapa G)" do
  let(:config_store) { Harness::ConfigStore.new(store: Harness::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  # ── MCP ──────────────────────────────────────────────────────────────────

  describe Harness::McpStore do
    subject(:store) { described_class.new(config_store: config_store) }

    it "upsert grava e devolve com env MASCARADO; get_raw devolve os valores reais" do
      masked = store.upsert("name" => "tavily", "transport" => "http", "url" => "https://x",
                            "env" => { "TAVILY_KEY" => "tvly-real" })
      expect(masked["env"]["TAVILY_KEY"]).to eq("__OCULTO__")
      expect(masked["enabled"]).to be(true) # default
      expect(store.get_raw("tavily")["env"]["TAVILY_KEY"]).to eq("tvly-real")
    end

    it "sentinel por chave preserva o segredo; string nova substitui; ausência limpa" do
      store.upsert("name" => "gh", "env" => { "TOKEN" => "ghp-1", "OTHER" => "keep" })
      # reenvia TOKEN como sentinel (preserva) e OTHER com valor novo
      store.upsert("name" => "gh", "env" => { "TOKEN" => "__OCULTO__", "OTHER" => "novo" })
      raw = store.get_raw("gh")["env"]
      expect(raw["TOKEN"]).to eq("ghp-1")  # preservado pelo sentinel
      expect(raw["OTHER"]).to eq("novo")   # substituído
      # chave omitida da submissão some
      store.upsert("name" => "gh", "env" => { "TOKEN" => "__OCULTO__" })
      expect(store.get_raw("gh")["env"]).to eq({ "TOKEN" => "ghp-1" })
    end

    it "name obrigatório; delete idempotente; all mascara" do
      expect { store.upsert("url" => "x") }.to raise_error(Harness::ValidationError, /name/)
      store.upsert("name" => "a", "env" => { "K" => "v" })
      expect(store.all.first["env"]["K"]).to eq("__OCULTO__")
      expect(store.delete("a")).to be(true)
      expect(store.delete("a")).to be(false)
    end

    it "enabled=false persiste como bool" do
      masked = store.upsert("name" => "off", "enabled" => false)
      expect(masked["enabled"]).to be(false)
    end
  end

  describe Harness::Commands::UpsertMcp do
    subject(:handler) { described_class.new(mcp_store: Harness::McpStore.new(config_store: config_store), event_stream: stream) }

    def cmd(payload) = Harness::Command.build(:upsert_mcp, payload)

    it "persiste mascarado e emite :mcp_upserted" do
      masked = handler.call(cmd("name" => "tavily", "env" => { "K" => "secret" }))
      expect(masked["env"]["K"]).to eq("__OCULTO__")
      expect(events.map(&:type)).to eq([:mcp_upserted])
    end
  end

  describe Harness::Commands::DeleteMcp do
    subject(:handler) { described_class.new(mcp_store: store, event_stream: stream) }
    let(:store) { Harness::McpStore.new(config_store: config_store) }

    def cmd(payload) = Harness::Command.build(:delete_mcp, payload)

    it "remove (existed) e emite; name obrigatório" do
      store.upsert("name" => "x")
      expect(handler.call(cmd("name" => "x"))).to eq({ existed: true })
      expect(handler.call(cmd("name" => "x"))).to eq({ existed: false })
      expect { handler.call(cmd({})) }.to raise_error(Harness::ValidationError, /name/)
    end
  end

  # ── System-files ─────────────────────────────────────────────────────────

  describe Harness::SystemFileStore do
    subject(:store) { described_class.new(config_store: config_store) }

    it "write/read/list e versiona o conteúdo anterior" do
      store.write("HOUSE.md", "v1")
      store.write("HOUSE.md", "v2")
      expect(store.read("HOUSE.md")).to eq("v2")
      expect(store.list).to eq(["HOUSE.md"])
      expect(store.versions("HOUSE.md").first["content"]).to eq("v1")
    end

    it "restore volta uma versão como nova escrita" do
      store.write("R.md", "a")
      store.write("R.md", "b")
      store.restore("R.md", 0) # 'a' era a versão 0 do history
      expect(store.read("R.md")).to eq("a")
    end

    it "delete idempotente; file vazio -> ValidationError; restore inválido levanta" do
      expect(store.delete("nope")).to be(false)
      expect { store.write("", "x") }.to raise_error(Harness::ValidationError, /file/)
      store.write("f.md", "x")
      expect { store.restore("f.md", 99) }.to raise_error(Harness::ValidationError, /versão/)
      expect { store.restore("ausente.md", 0) }.to raise_error(Harness::NotFoundError)
    end
  end

  describe "system-file commands" do
    let(:store) { Harness::SystemFileStore.new(config_store: config_store) }

    it "write emite :system_file_written e exige file" do
      h = Harness::Commands::WriteSystemFile.new(system_file_store: store, event_stream: stream)
      h.call(Harness::Command.build(:write_system_file, { "file" => "H.md", "content" => "regras" }))
      expect(store.read("H.md")).to eq("regras")
      expect(events.map(&:type)).to eq([:system_file_written])
      expect { h.call(Harness::Command.build(:write_system_file, { "content" => "x" })) }
        .to raise_error(Harness::ValidationError, /file/)
    end

    it "delete e restore emitem seus eventos" do
      store.write("H.md", "a")
      store.write("H.md", "b")
      Harness::Commands::RestoreSystemFile.new(system_file_store: store, event_stream: stream)
        .call(Harness::Command.build(:restore_system_file, { "file" => "H.md", "version" => "0" }))
      expect(store.read("H.md")).to eq("a")
      Harness::Commands::DeleteSystemFile.new(system_file_store: store, event_stream: stream)
        .call(Harness::Command.build(:delete_system_file, { "file" => "H.md" }))
      expect(store.read("H.md")).to be_nil
      expect(events.map(&:type)).to eq(%i[system_file_restored system_file_deleted])
    end
  end

  # ── Injeção global no Prompt provider ──────────────────────────────────────

  describe "Prompt provider · injeção global" do
    let(:store) { Harness::SystemFileStore.new(config_store: config_store) }
    let(:profile) { Harness::AgentProfile.build(id: "bia", model: "m", provider: :deepseek, memory: true) }
    let(:request) { Struct.new(:profile).new(profile) }

    it "sem arquivos de sistema o prompt é idêntico (paridade)" do
      provider = Harness::Context::Providers::Prompt.new(base: "BASE", system_files: store)
      expect(provider.call(request).first.content).to eq("BASE")
    end

    it "injeta os arquivos de sistema ANTES da identidade, para todo agente" do
      store.write("HOUSE.md", "REGRAS DA CASA")
      provider = Harness::Context::Providers::Prompt.new(base: "BASE", system_files: store)
      content = provider.call(request).first.content
      expect(content).to eq("BASE\n\nREGRAS DA CASA")
    end
  end
end

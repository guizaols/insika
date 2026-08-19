# frozen_string_literal: true

require "spec_helper"

# (tasks 18-19): MCP instances (durable config, masked
# credentials) + global system files (injected into every agent by the
# Prompt provider). Runs WITHOUT a key/gem — pure stores over the Memory backend.
RSpec.describe "MCP + system-files" do
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  # ── MCP ──────────────────────────────────────────────────────────────────

  describe Insika::McpStore do
    subject(:store) { described_class.new(config_store: config_store) }

    it "upsert stores and returns with MASKED env; get_raw returns the real values" do
      masked = store.upsert("name" => "tavily", "transport" => "http", "url" => "https://x",
                            "env" => { "TAVILY_KEY" => "tvly-real" })
      expect(masked["env"]["TAVILY_KEY"]).to eq("__OCULTO__")
      expect(masked["enabled"]).to be(true) # default
      expect(store.get_raw("tavily")["env"]["TAVILY_KEY"]).to eq("tvly-real")
    end

    it "per-key sentinel preserves the secret; a new string replaces it; absence clears it" do
      store.upsert("name" => "gh", "env" => { "TOKEN" => "ghp-1", "OTHER" => "keep" })
      # resend TOKEN as the sentinel (preserves) and OTHER with a new value
      store.upsert("name" => "gh", "env" => { "TOKEN" => "__OCULTO__", "OTHER" => "novo" })
      raw = store.get_raw("gh")["env"]
      expect(raw["TOKEN"]).to eq("ghp-1")  # preserved by the sentinel
      expect(raw["OTHER"]).to eq("novo")   # replaced
      # a key omitted from the submission disappears
      store.upsert("name" => "gh", "env" => { "TOKEN" => "__OCULTO__" })
      expect(store.get_raw("gh")["env"]).to eq({ "TOKEN" => "ghp-1" })
    end

    it "name required; delete idempotent; all masks" do
      expect { store.upsert("url" => "x") }.to raise_error(Insika::ValidationError, /name/)
      store.upsert("name" => "a", "env" => { "K" => "v" })
      expect(store.all.first["env"]["K"]).to eq("__OCULTO__")
      expect(store.delete("a")).to be(true)
      expect(store.delete("a")).to be(false)
    end

    it "enabled=false persists as a bool" do
      masked = store.upsert("name" => "off", "enabled" => false)
      expect(masked["enabled"]).to be(false)
    end
  end

  describe Insika::Commands::UpsertMcp do
    subject(:handler) { described_class.new(mcp_store: Insika::McpStore.new(config_store: config_store), event_stream: stream) }

    def cmd(payload) = Insika::Command.build(:upsert_mcp, payload)

    it "persists masked and emits :mcp_upserted" do
      masked = handler.call(cmd("name" => "tavily", "env" => { "K" => "secret" }))
      expect(masked["env"]["K"]).to eq("__OCULTO__")
      expect(events.map(&:type)).to eq([:mcp_upserted])
    end
  end

  describe Insika::Commands::DeleteMcp do
    subject(:handler) { described_class.new(mcp_store: store, event_stream: stream) }
    let(:store) { Insika::McpStore.new(config_store: config_store) }

    def cmd(payload) = Insika::Command.build(:delete_mcp, payload)

    it "removes (existed) and emits; name required" do
      store.upsert("name" => "x")
      expect(handler.call(cmd("name" => "x"))).to eq({ existed: true })
      expect(handler.call(cmd("name" => "x"))).to eq({ existed: false })
      expect { handler.call(cmd({})) }.to raise_error(Insika::ValidationError, /name/)
    end
  end

  # ── System-files ─────────────────────────────────────────────────────────

  describe Insika::SystemFileStore do
    subject(:store) { described_class.new(config_store: config_store) }

    it "write/read/list and versions the previous content" do
      store.write("HOUSE.md", "v1")
      store.write("HOUSE.md", "v2")
      expect(store.read("HOUSE.md")).to eq("v2")
      expect(store.list).to eq(["HOUSE.md"])
      expect(store.versions("HOUSE.md").first["content"]).to eq("v1")
    end

    it "restore brings a version back as a new write" do
      store.write("R.md", "a")
      store.write("R.md", "b")
      store.restore("R.md", 0) # 'a' was version 0 of the history
      expect(store.read("R.md")).to eq("a")
    end

    it "delete idempotent; empty file -> ValidationError; invalid restore raises" do
      expect(store.delete("nope")).to be(false)
      expect { store.write("", "x") }.to raise_error(Insika::ValidationError, /file/)
      store.write("f.md", "x")
      expect { store.restore("f.md", 99) }.to raise_error(Insika::ValidationError, /version/)
      expect { store.restore("missing.md", 0) }.to raise_error(Insika::NotFoundError)
    end
  end

  describe "system-file commands" do
    let(:store) { Insika::SystemFileStore.new(config_store: config_store) }

    it "write emits :system_file_written and requires file" do
      h = Insika::Commands::WriteSystemFile.new(system_file_store: store, event_stream: stream)
      h.call(Insika::Command.build(:write_system_file, { "file" => "H.md", "content" => "regras" }))
      expect(store.read("H.md")).to eq("regras")
      expect(events.map(&:type)).to eq([:system_file_written])
      expect { h.call(Insika::Command.build(:write_system_file, { "content" => "x" })) }
        .to raise_error(Insika::ValidationError, /file/)
    end

    it "delete and restore emit their events" do
      store.write("H.md", "a")
      store.write("H.md", "b")
      Insika::Commands::RestoreSystemFile.new(system_file_store: store, event_stream: stream)
        .call(Insika::Command.build(:restore_system_file, { "file" => "H.md", "version" => "0" }))
      expect(store.read("H.md")).to eq("a")
      Insika::Commands::DeleteSystemFile.new(system_file_store: store, event_stream: stream)
        .call(Insika::Command.build(:delete_system_file, { "file" => "H.md" }))
      expect(store.read("H.md")).to be_nil
      expect(events.map(&:type)).to eq(%i[system_file_restored system_file_deleted])
    end
  end

  # ── Global injection into the Prompt provider ──────────────────────────────

  describe "Prompt provider · global injection" do
    let(:store) { Insika::SystemFileStore.new(config_store: config_store) }
    let(:profile) { Insika::AgentProfile.build(id: "bia", model: "m", provider: :deepseek, memory: true) }
    let(:request) { Struct.new(:profile).new(profile) }

    it "without system files the prompt is the base + the engine discipline block" do
      provider = Insika::Context::Providers::Prompt.new(base: "BASE", system_files: store)
      expect(provider.call(request).first.content)
        .to eq("BASE\n\n#{Insika::Context::Providers::Prompt::TOOL_PERSISTENCE}")
    end

    it "injects the system files BEFORE the identity, for every agent" do
      store.write("HOUSE.md", "REGRAS DA CASA")
      provider = Insika::Context::Providers::Prompt.new(base: "BASE", system_files: store)
      content = provider.call(request).first.content
      expect(content)
        .to eq("BASE\n\nREGRAS DA CASA\n\n#{Insika::Context::Providers::Prompt::TOOL_PERSISTENCE}")
    end
  end
end

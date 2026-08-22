# frozen_string_literal: true

require "spec_helper"

# One parser shared by the CLI/API/Studio config surfaces.
RSpec.describe Insika::McpJson do
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:mcp_store) { Insika::McpStore.new(config_store: config_store) }

  describe ".import" do
    it "accepts a JSON string and upserts a stdio + an http entry, defaulting transport by shape" do
      json = JSON.generate({
        "mcpServers" => {
          "filesystem" => { "command" => "npx", "args" => ["-y", "server-filesystem", "/tmp"] },
          "tavily" => { "url" => "https://mcp.tavily.com/mcp", "headers" => { "Authorization" => "Bearer secret" } }
        }
      })

      records = described_class.import(json, mcp_store: mcp_store)

      expect(records.map { |r| r["name"] }).to eq(%w[filesystem tavily])
      fs = mcp_store.get_raw("filesystem")
      expect(fs["transport"]).to eq("stdio")
      expect(fs["args"]).to eq(["-y", "server-filesystem", "/tmp"])
      tavily = mcp_store.get_raw("tavily")
      expect(tavily["transport"]).to eq("http")
      expect(tavily["headers"]).to eq({ "Authorization" => "Bearer secret" })
      # never returns plaintext, even though we just wrote it
      expect(records.last["headers"]["Authorization"]).to eq("__OCULTO__")
    end

    it "accepts an already-parsed Hash (symbol or string keys)" do
      records = described_class.import({ mcpServers: { "weather" => { "url" => "https://x", "transport" => "sse" } } },
                                        mcp_store: mcp_store)
      expect(records.first["name"]).to eq("weather")
      expect(mcp_store.get_raw("weather")["transport"]).to eq("sse")
    end

    it "an empty mcpServers imports nothing" do
      expect(described_class.import({}, mcp_store: mcp_store)).to eq([])
    end

    it "re-importing an export's __OCULTO__ sentinel never wipes an existing credential" do
      mcp_store.upsert("name" => "tavily", "transport" => "http", "url" => "https://mcp.tavily.com/mcp",
                       "headers" => { "Authorization" => "Bearer real" })
      exported = described_class.export(mcp_store: mcp_store)

      described_class.import(exported, mcp_store: mcp_store)

      expect(mcp_store.get_raw("tavily")["headers"]["Authorization"]).to eq("Bearer real")
    end
  end

  describe ".export" do
    it "round-trips a stdio instance with args/env, masked" do
      mcp_store.upsert("name" => "fs", "transport" => "stdio", "command" => "npx",
                       "args" => ["-y", "server-filesystem"], "env" => { "HOME" => "/tmp" },
                       "description" => "local files")

      doc = described_class.export(mcp_store: mcp_store)

      expect(doc).to eq({
                          "mcpServers" => {
                            "fs" => { "command" => "npx", "args" => ["-y", "server-filesystem"],
                                      "env" => { "HOME" => "__OCULTO__" },
                                      "transport" => "stdio", "description" => "local files", "enabled" => true }
                          }
                        })
    end

    it "round-trips an http instance without leaking the url/headers structure" do
      mcp_store.upsert("name" => "tavily", "transport" => "http", "url" => "https://mcp.tavily.com/mcp",
                       "headers" => { "Authorization" => "Bearer real" }, "enabled" => false)

      doc = described_class.export(mcp_store: mcp_store)

      expect(doc["mcpServers"]["tavily"]).to eq({
                                                   "url" => "https://mcp.tavily.com/mcp",
                                                   "headers" => { "Authorization" => "__OCULTO__" },
                                                   "transport" => "http", "enabled" => false
                                                 })
    end

    it "no instances -> an empty mcpServers" do
      expect(described_class.export(mcp_store: mcp_store)).to eq({ "mcpServers" => {} })
    end
  end
end

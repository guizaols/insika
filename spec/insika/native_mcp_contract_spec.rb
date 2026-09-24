# frozen_string_literal: true

require "spec_helper"
require "socket"
require "rbconfig"
require_relative "../fixtures/mcp_contract_server"

RSpec.describe "Native MCP integration" do
  let(:store) { Insika::McpStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:env) do
    values = { "INSIKA_MCP_STDIO" => "1", "INSIKA_EGRESS_ALLOW_HTTP" => "1",
               "INSIKA_EGRESS_ALLOW_PRIVATE" => "1", "INSIKA_EGRESS_HOSTS" => "127.0.0.1" }
    double(read: nil).tap do |reader|
      allow(reader).to receive(:read) { |key| values[key] }
      allow(reader).to receive(:truthy?) { |value| Insika::EnvSchema.truthy?(value) }
    end
  end
  let(:registry) do
    Insika::McpToolRegistry.new(mcp_store: store,
      client_factory: ->(record) { Insika::McpClient.for(record, env_reader: env) })
  end

  [false, true].each do |legacy|
    it "discovers and executes over stdio with #{legacy ? 'legacy handshake' : 'modern discovery'}" do
      store.upsert(name: "fixture", transport: "stdio", command: RbConfig.ruby,
        args: [File.expand_path("../fixtures/mcp_contract_server.rb", __dir__)],
        env: { "MCP_LEGACY" => legacy ? "1" : "0" })
      registry.refresh("fixture")
      entry = registry.entries.first
      expect(entry.metadata[:side_effect]).to be(false)
      tool = entry.factory.call
      expect(tool.call(text: "hello")).to eq("hello")
      expect(tool.call(text: "fail")).to eq(error: "fail")
      expect(JSON.parse(tool.call(text: "structured"))).to eq("products" => [{ "id" => "p1" }])
      parts = tool.call(text: "image")
      expect(parts.first).to eq("image")
      expect(parts.last).to be_a(RubyLLM::Attachment)
      expect(parts.last.content).to eq("hello")
    ensure
      registry.evict("fixture")
    end
  end

  [false, true].each do |legacy|
    it "uses Streamable HTTP with #{legacy ? 'legacy handshake' : 'modern discovery'}, preserving authorization" do
      server = TCPServer.new("127.0.0.1", 0)
      headers_seen = []
      worker = Thread.new do
        loop do
          socket = server.accept
          begin
            socket.gets
            headers = {}
            while (line = socket.gets) && line != "\r\n"
              key, value = line.strip.split(":", 2)
              headers[key.downcase] = value.strip
            end
            headers_seen << headers
            message = JSON.parse(socket.read(Integer(headers.fetch("content-length"))))
            response = McpContractServer.reply(message, legacy: legacy)
            body = response ? "event: message\ndata: #{JSON.generate(response)}\n\n" : ""
            status = response ? "200 OK" : "202 Accepted"
            session = message["method"] == "initialize" ? "Mcp-Session-Id: fixture-session\r\n" : ""
            socket.write("HTTP/1.1 #{status}\r\nContent-Type: text/event-stream\r\n#{session}" \
                         "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          ensure
            socket.close
          end
        end
      end
      store.upsert(name: "fixture", transport: "http", url: "http://127.0.0.1:#{server.addr[1]}/mcp",
        headers: { "Authorization" => "Bearer spec-only" })
      Sync do
        registry.refresh("fixture")
        expect(registry.entries.first.factory.call.call(text: "hello")).to eq("hello")
      end
      expect(headers_seen.size).to eq(legacy ? 5 : 3)
      expect(headers_seen).to all(include("authorization" => "Bearer spec-only"))
      expect(headers_seen).to all(satisfy { |headers| !headers.key?("origin") })
      expect(headers_seen.last["mcp-session-id"]).to eq("fixture-session") if legacy
    ensure
      registry.evict("fixture")
      worker&.kill
      worker&.join
      server&.close
    end
  end
end

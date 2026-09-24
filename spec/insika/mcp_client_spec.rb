# frozen_string_literal: true

require "spec_helper"

# Insika::McpClient — the seam between an McpStore record and a live
# RubyLLM::MCP. Builds only: `for` never starts the
# client, so these specs never spawn a process or touch the network.
RSpec.describe Insika::McpClient do
  AllowEgress = Class.new { def violation(*, **) = nil }.new
  BlockEgress = Class.new { def violation(*, **) = "private-network destination blocked" }.new

  def env_reader(stdio_on:)
    Class.new do
      define_method(:read) { |_name| stdio_on ? "1" : nil }
      define_method(:truthy?) { |v| Insika::EnvSchema.truthy?(v) }
    end.new
  end

  it "stdio with the gate off raises StdioDisabled" do
    record = { "name" => "fs", "transport" => "stdio", "command" => "npx", "args" => [] }

    expect { described_class.for(record, env_reader: env_reader(stdio_on: false)) }
      .to raise_error(Insika::McpClient::StdioDisabled, /INSIKA_MCP_STDIO/)
  end

  it "stdio with the gate on builds an unstarted stdio client from command/args/env" do
    record = { "name" => "fs", "transport" => "stdio", "command" => "npx",
              "args" => ["-y", "@modelcontextprotocol/server-filesystem"], "env" => { "HOME" => "/tmp" } }

    client = described_class.for(record, env_reader: env_reader(stdio_on: true))

    expect(client).to be_a(RubyLLM::MCP)
    expect(client.class.command).to eq(["npx", "-y", "@modelcontextprotocol/server-filesystem"])
    expect(client.class.env).to eq({ "HOME" => "/tmp" })
  end

  it "http builds an unstarted streamable_http client from url/headers, guarded by egress" do
    record = { "name" => "tavily", "transport" => "http", "url" => "https://mcp.test/rpc",
              "headers" => { "Authorization" => "Bearer x" } }

    client = described_class.for(record, egress: AllowEgress)

    expect(client).to be_a(RubyLLM::MCP)
    expect(client.class.url).to eq("https://mcp.test/rpc")
    expect(client.class.headers).to eq({ "Authorization" => "Bearer x" })
  end

  it "reports the replacement required for a legacy SSE record without changing it" do
    record = { "name" => "tavily", "transport" => "sse", "url" => "https://mcp.test/sse" }

    expect { described_class.for(record, egress: AllowEgress) }
      .to raise_error(Insika::ValidationError, /Streamable HTTP/)
    expect(record["transport"]).to eq("sse")
  end

  it "http/sse egress-blocked url raises Insika::Error" do
    record = { "name" => "tavily", "transport" => "http", "url" => "http://169.254.169.254/" }

    expect { described_class.for(record, egress: BlockEgress) }.to raise_error(Insika::Error, /blocked/)
  end

  it "unknown transport raises Insika::ValidationError" do
    record = { "name" => "x", "transport" => "carrier-pigeon" }

    expect { described_class.for(record, egress: AllowEgress) }.to raise_error(Insika::ValidationError, /unknown transport/)
  end

  it "rejects non-loopback HTTP even when the deployment egress permits it" do
    record = { "name" => "sidecar", "transport" => "http", "url" => "http://store:8931/mcp" }
    expect { described_class.for(record, egress: AllowEgress) }
      .to raise_error(Insika::ValidationError, /HTTPS/)
  end

  # The gap a cross-harness bench found: an MCP server on the deployment's own
  # private network (a sidecar in the same compose file) was blocked with no flag
  # that could say yes, while a data-tool pointed at the same host had one.
  describe "the egress opt-ins" do
    RecordingEgress = Class.new do
      attr_reader :seen

      def violation(_url, **options)
        @seen = options
        nil
      end
    end

    def env(values)
      Class.new do
        define_method(:read) { |name| values[name] }
        define_method(:truthy?) { |v| Insika::EnvSchema.truthy?(v) }
      end.new
    end

    let(:record) { { "name" => "store", "transport" => "http", "url" => "http://localhost:8931/mcp" } }

    it "passes the same env opt-ins a data-tool obeys" do
      egress = RecordingEgress.new
      described_class.for(record, egress: egress,
                                  env_reader: env("INSIKA_EGRESS_ALLOW_HTTP" => "true",
                                                  "INSIKA_EGRESS_ALLOW_PRIVATE" => "1",
                                                  "INSIKA_EGRESS_HOSTS" => "store, localhost"))

      expect(egress.seen).to eq(allow_http: true, allow_private: true,
                                host_allowlist: %w[store localhost])
    end

    it "stays strict when nobody opted out" do
      egress = RecordingEgress.new
      described_class.for(record, egress: egress, env_reader: env({}))

      expect(egress.seen).to eq(allow_http: false, allow_private: false)
    end
  end
end

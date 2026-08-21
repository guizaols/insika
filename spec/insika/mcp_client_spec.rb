# frozen_string_literal: true

require "spec_helper"

# Insika::McpClient — the seam between an McpStore record and a live
# RubyLLM::MCP::Client (RFC-0040). Builds only: `for` never starts the
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

    expect(client.transport_type).to eq(:stdio)
    expect(client.config[:command]).to eq("npx")
    expect(client.config[:args]).to eq(["-y", "@modelcontextprotocol/server-filesystem"])
    expect(client.config[:env]).to eq({ "HOME" => "/tmp" })
    expect(client).not_to be_alive
  end

  it "http builds an unstarted streamable_http client from url/headers, guarded by egress" do
    record = { "name" => "tavily", "transport" => "http", "url" => "https://mcp.test/rpc",
              "headers" => { "Authorization" => "Bearer x" } }

    client = described_class.for(record, egress: AllowEgress)

    expect(client.transport_type).to eq(:streamable_http)
    expect(client.config[:url]).to eq("https://mcp.test/rpc")
    expect(client.config[:headers]).to eq({ "Authorization" => "Bearer x" })
  end

  it "sse builds an unstarted sse client" do
    record = { "name" => "tavily", "transport" => "sse", "url" => "https://mcp.test/sse" }

    expect(described_class.for(record, egress: AllowEgress).transport_type).to eq(:sse)
  end

  it "http/sse egress-blocked url raises Insika::Error" do
    record = { "name" => "tavily", "transport" => "http", "url" => "http://169.254.169.254/" }

    expect { described_class.for(record, egress: BlockEgress) }.to raise_error(Insika::Error, /blocked/)
  end

  it "unknown transport raises Insika::ValidationError" do
    record = { "name" => "x", "transport" => "carrier-pigeon" }

    expect { described_class.for(record, egress: AllowEgress) }.to raise_error(Insika::ValidationError, /unknown transport/)
  end

  # ruby_llm-mcp's StreamableHTTP#build_common_headers sets `Origin` to the
  # endpoint's OWN url (path included) on every request — invalid per RFC
  # 6454 (Origin is scheme+host[+port], never a path) and unneeded, since a
  # server-to-server client has none to report. No server allowlist can
  # match a value with a path, so any MCP server enforcing the spec's
  # DNS-rebinding Origin check (GitHub's remote MCP, Grafana, Metabase, ...)
  # rejects every request. https://github.com/patvice/ruby_llm-mcp/issues/140
  # (open, unfixed as of 1.0.1) — `for` prepends a fix stripping it.
  it "strips the gem's spec-incorrect Origin header from a streamable_http request" do
    record = { "name" => "tavily", "transport" => "http", "url" => "https://mcp.test/rpc",
              "headers" => { "Authorization" => "Bearer x" } }
    described_class.for(record, egress: AllowEgress) # loads the gem + applies the fix

    transport = RubyLLM::MCP::Native::Transports::StreamableHTTP.new(
      url: "https://mcp.test/rpc", request_timeout: 5000, coordinator: Object.new,
      headers: { "Authorization" => "Bearer x" }
    )
    headers = transport.send(:build_common_headers)

    expect(headers).not_to have_key("Origin")
    expect(headers["Authorization"]).to eq("Bearer x")
  end
end

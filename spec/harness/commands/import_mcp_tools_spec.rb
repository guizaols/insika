# frozen_string_literal: true

require "spec_helper"

# Phase 7, Stage E: Command :import_mcp_tools — takes the MCP instance name,
# delegates to the ingestor (discover -> ingest) and emits :mcp_tools_imported with
# counts only. Per-tool report in the same shape as :import_tools + `instance:`.
RSpec.describe Harness::Commands::ImportMcpTools do
  # ingestor double: records the ingested name, returns a fixed report.
  class IngestorSpy
    attr_reader :ingested

    def initialize(report) = (@report = report; @ingested = [])
    def ingest(name, client: nil) = (@ingested << name; @report.merge(instance: name.to_s))
  end

  let(:events) { SpyEventStream.new }
  let(:report) { { version: 1, created: %w[search extract], updated: [], errors: [] } }
  let(:ingestor) { IngestorSpy.new(report) }
  let(:command) { described_class.new(ingestor: ingestor, event_stream: events) }

  def run(payload) = command.call(Harness::Command.build(:import_mcp_tools, payload, transport: :test))

  it "delegates to the ingestor and returns the report + instance" do
    out = run(name: "tavily")
    expect(ingestor.ingested).to eq(["tavily"])
    expect(out).to include(instance: "tavily", created: %w[search extract])
  end

  it "accepts a string key (raw transport payload)" do
    out = run("name" => "tavily")
    expect(out[:instance]).to eq("tavily")
  end

  it "emits :mcp_tools_imported with COUNTS + instance only" do
    run(name: "tavily")
    ev = events.events.last
    expect(ev.type).to eq(:mcp_tools_imported)
    expect(ev.data).to eq(instance: "tavily", created: 2, updated: 0, errors: 0)
  end

  it "missing name -> ValidationError (does not call the ingestor)" do
    expect { run({}) }.to raise_error(Harness::ValidationError, /name/)
    expect(ingestor.ingested).to be_empty
  end
end

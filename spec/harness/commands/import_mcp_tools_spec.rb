# frozen_string_literal: true

require "spec_helper"

# Fase 7, Etapa E: Command :import_mcp_tools — recebe o nome da instância MCP,
# delega ao ingestor (descobre -> ingere) e emite :mcp_tools_imported só com
# contagens. Relatório por-tool no molde do :import_tools + `instance:`.
RSpec.describe Harness::Commands::ImportMcpTools do
  # ingestor duplo: grava o nome ingerido, devolve um relatório fixo.
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

  it "delega ao ingestor e devolve o relatório + instance" do
    out = run(name: "tavily")
    expect(ingestor.ingested).to eq(["tavily"])
    expect(out).to include(instance: "tavily", created: %w[search extract])
  end

  it "aceita chave string (payload cru do transporte)" do
    out = run("name" => "tavily")
    expect(out[:instance]).to eq("tavily")
  end

  it "emite :mcp_tools_imported só com CONTAGENS + instância" do
    run(name: "tavily")
    ev = events.events.last
    expect(ev.type).to eq(:mcp_tools_imported)
    expect(ev.data).to eq(instance: "tavily", created: 2, updated: 0, errors: 0)
  end

  it "name ausente -> ValidationError (não chama o ingestor)" do
    expect { run({}) }.to raise_error(Harness::ValidationError, /name/)
    expect(ingestor.ingested).to be_empty
  end
end

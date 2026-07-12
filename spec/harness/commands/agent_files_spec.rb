# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa C: Commands de arquivos de prompt por-agente (workspace).
RSpec.describe "Commands de workspace de agente (Fase 4 Etapa C)" do
  let(:config_store) { Harness::ConfigStore.new(store: Harness::Stores::Memory.new) }
  let(:source) { Harness::StoredProfileSource.new(config_store: config_store) }
  let(:files) { Harness::AgentFileStore.new(config_store: config_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Harness::Command.build(type, payload)
  before { source.put(Harness::AgentProfile.build(id: "bia", model: "m")) }

  describe Harness::Commands::WriteAgentFile do
    subject(:handler) { described_class.new(profile_source: source, agent_file_store: files, event_stream: stream) }

    it "grava o arquivo do agente; emite :agent_file_written" do
      res = handler.call(cmd(:write_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md", "content" => "Sou a Bia." }))
      expect(res[:file]).to eq("IDENTITY.md")
      expect(files.read("bia", "IDENTITY.md")).to eq("Sou a Bia.")
      expect(events.map(&:type)).to eq([:agent_file_written])
    end

    it "agent_id/file obrigatórios; agente inexistente -> NotFoundError" do
      expect { handler.call(cmd(:write_agent_file, { "file" => "x" })) }.to raise_error(Harness::ValidationError, /agent_id/)
      expect { handler.call(cmd(:write_agent_file, { "agent_id" => "bia" })) }.to raise_error(Harness::ValidationError, /file/)
      expect { handler.call(cmd(:write_agent_file, { "agent_id" => "nope", "file" => "x", "content" => "y" })) }
        .to raise_error(Harness::NotFoundError)
    end

    it "create_only recusa sobrescrever" do
      handler.call(cmd(:write_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md", "content" => "v1" }))
      expect { handler.call(cmd(:write_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md", "content" => "v2", "create_only" => true })) }
        .to raise_error(Harness::ValidationError, /já existe/)
    end
  end

  describe Harness::Commands::DeleteAgentFile do
    subject(:handler) { described_class.new(profile_source: source, agent_file_store: files, event_stream: stream) }

    it "remove o arquivo; inexistente -> NotFoundError" do
      files.write("bia", "IDENTITY.md", "x")
      handler.call(cmd(:delete_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md" }))
      expect(files.read("bia", "IDENTITY.md")).to be_nil
      expect(events.map(&:type)).to include(:agent_file_deleted)
      expect { handler.call(cmd(:delete_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md" })) }
        .to raise_error(Harness::NotFoundError)
    end
  end

  describe Harness::Commands::RestoreAgentFile do
    subject(:handler) { described_class.new(profile_source: source, agent_file_store: files, event_stream: stream) }

    it "restaura uma versão antiga como conteúdo atual; emite :agent_file_restored" do
      files.write("bia", "IDENTITY.md", "v1")
      files.write("bia", "IDENTITY.md", "v2")
      handler.call(cmd(:restore_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md", "version" => 0 }))
      expect(files.read("bia", "IDENTITY.md")).to eq("v1")
      expect(events.map(&:type)).to include(:agent_file_restored)
    end

    it "version obrigatório; índice inválido -> ValidationError" do
      files.write("bia", "IDENTITY.md", "v1")
      expect { handler.call(cmd(:restore_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md" })) }
        .to raise_error(Harness::ValidationError, /version/)
      expect { handler.call(cmd(:restore_agent_file, { "agent_id" => "bia", "file" => "IDENTITY.md", "version" => 9 })) }
        .to raise_error(Harness::ValidationError)
    end
  end
end

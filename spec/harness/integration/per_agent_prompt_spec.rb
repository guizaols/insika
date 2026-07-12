# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Fase 4 Etapa C (critério): resolve a limitação conhecida — um agente novo NÃO
# herda mais o prompt da Bia. Cada BIA tem identidade própria, autorada em
# runtime (create_agent + write_agent_file), lida pelo Prompt provider a partir
# do profile.prompt_files → AgentFileStore. Tudo pelo mesmo Store, sem restart.
RSpec.describe "Integração: identidade de prompt por-agente (Fase 4 Etapa C)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:config_store) { Harness::ConfigStore.new(store: backend) }
  let(:source) { Harness::StoredProfileSource.new(config_store: config_store) }
  let(:agent_files) { Harness::AgentFileStore.new(config_store: config_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  # O DEFAULT de deployment (files do wiring): um agente SEM prompt_files o herda.
  let(:default_identity) do
    dir = Dir.mktmpdir
    File.write(File.join(dir, "SOUL.md"), "Sou a Bia, atendente padrão.")
    [File.join(dir, "SOUL.md")]
  end

  let(:provider) do
    Harness::Context::Providers::Prompt.new(base: "", files: default_identity, agent_files: agent_files)
  end

  def create_agent(payload)
    Harness::Commands::CreateAgent.new(profile_source: source, event_stream: stream)
      .call(Harness::Command.build(:create_agent, payload))
  end

  def write_file(payload)
    Harness::Commands::WriteAgentFile.new(profile_source: source, agent_file_store: agent_files, event_stream: stream)
      .call(Harness::Command.build(:write_agent_file, payload))
  end

  def identity_for(agent_id)
    profile = source.fetch(agent_id)
    request = Harness::ContextRequest.new(session: nil, message: "oi", profile: profile, tenant: nil, vars: {}, checkpoint: nil)
    provider.call(request).first&.content
  end

  it "agente com identidade própria NÃO herda o default; agente sem prompt_files herda" do
    # Bia: sem prompt_files -> herda o default do deployment (paridade Fase 0).
    create_agent({ "id" => "bia", "model" => "m" })

    # Chef: criado com prompt_files próprios + conteúdo autorado em runtime.
    create_agent({ "id" => "chef", "model" => "m", "prompt_files" => %w[IDENTITY.md] })
    write_file({ "agent_id" => "chef", "file" => "IDENTITY.md",
                 "content" => "Sou o Chef, especialista em massas artesanais." })

    expect(identity_for("bia")).to eq("Sou a Bia, atendente padrão.")
    expect(identity_for("chef")).to eq("Sou o Chef, especialista em massas artesanais.")
    expect(identity_for("chef")).not_to include("Bia") # a limitação está resolvida
  end

  it "editar o arquivo do agente vale no próximo dispatch (hot, sem restart)" do
    create_agent({ "id" => "chef", "model" => "m", "prompt_files" => %w[IDENTITY.md] })
    write_file({ "agent_id" => "chef", "file" => "IDENTITY.md", "content" => "v1" })
    expect(identity_for("chef")).to eq("v1")

    write_file({ "agent_id" => "chef", "file" => "IDENTITY.md", "content" => "v2 — identidade revisada" })
    expect(identity_for("chef")).to eq("v2 — identidade revisada")
  end
end

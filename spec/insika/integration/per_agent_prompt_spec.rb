# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# (criterion): resolves the known limitation — a new agent NO
# longer inherits Bia's prompt. Each BIA has its own identity, authored at
# runtime (create_agent + write_agent_file), read by the Prompt provider from
# profile.prompt_files → AgentFileStore. All through the same Store, no restart.
#
# There is no deployment-wide fallback identity: a `copilot` data agent
# provisioned without its own prompt_files/base_prompt inherited the
# deployment's demo persona byte for byte in production (confirmed live,
# 2026-08-24) — the fallback this suite used to exercise IS that bug.
RSpec.describe "Integration: per-agent prompt identity" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:source) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:agent_files) { Insika::AgentFileStore.new(config_store: config_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  let(:provider) do
    Insika::Context::Providers::Prompt.new(base: "", agent_files: agent_files)
  end

  def create_agent(payload)
    Insika::Commands::CreateAgent.new(profile_source: source, event_stream: stream)
      .call(Insika::Command.build(:create_agent, payload))
  end

  def write_file(payload)
    Insika::Commands::WriteAgentFile.new(profile_source: source, agent_file_store: agent_files, event_stream: stream)
      .call(Insika::Command.build(:write_agent_file, payload))
  end

  def identity_for(agent_id)
    profile = source.fetch(agent_id)
    request = Insika::ContextRequest.new(session: nil, message: "oi", profile: profile, tenant: nil, vars: {}, checkpoint: nil)
    provider.call(request).first&.content
  end

  it "an agent with its own identity does NOT inherit anyone else's; without prompt_files it refuses to run" do
    # A DIFFERENT agent's identity, authored at runtime — must never leak.
    create_agent({ "id" => "bia", "model" => "m", "prompt_files" => %w[IDENTITY.md],
                   "tool_persistence" => false })
    write_file({ "agent_id" => "bia", "file" => "IDENTITY.md", "content" => "Sou a Bia, atendente padrão." })

    # Chef: created with its own prompt_files + content authored at runtime.
    create_agent({ "id" => "chef", "model" => "m", "prompt_files" => %w[IDENTITY.md],
                   "tool_persistence" => false })
    write_file({ "agent_id" => "chef", "file" => "IDENTITY.md",
                 "content" => "Sou o Chef, especialista em massas artesanais." })

    expect(identity_for("chef")).to eq("Sou o Chef, especialista em massas artesanais.")
    expect(identity_for("chef")).not_to include("Bia") # the limitation is resolved

    # An agent with NEITHER prompt_files NOR base_prompt: refuses to run
    # rather than silently borrow Bia's or Chef's.
    create_agent({ "id" => "no-identity", "model" => "m", "tool_persistence" => false })
    expect { identity_for("no-identity") }.to raise_error(Insika::ContextError)
  end

  it "editing the agent's file takes effect on the next dispatch (hot, no restart)" do
    create_agent({ "id" => "chef", "model" => "m", "prompt_files" => %w[IDENTITY.md],
                   "tool_persistence" => false })
    write_file({ "agent_id" => "chef", "file" => "IDENTITY.md", "content" => "v1" })
    expect(identity_for("chef")).to eq("v1")

    write_file({ "agent_id" => "chef", "file" => "IDENTITY.md", "content" => "v2 — identidade revisada" })
    expect(identity_for("chef")).to eq("v2 — identidade revisada")
  end
end

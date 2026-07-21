# frozen_string_literal: true

require "spec_helper"
require_relative "../../config/deployment" # concrete deployment root (builds the graph eager)

# Characterization of the CONCRETE deployment composition root (§12 G4 / §11.2 B4,
# commit 1). config/deployment.rb had NO spec — consolidating the two roots into a
# shared builder requires locking the observable graph FIRST, so the extraction is
# provably behavior-preserving. These are graph assertions (handlers on the BUS,
# stores over the same BACKEND, idempotent seed), not turn behavior.
RSpec.describe Deploy::Wiring do
  let(:w) { described_class }

  describe "persistence backend" do
    it "builds every domain store over the SAME single BACKEND instance" do
      backend = w::BACKEND
      %i[SESSION_STORE TASK_STORE CHECKPOINT_STORE PENDING_ACTION_STORE MEMORY_STORE].each do |const|
        store = w.const_get(const)
        expect(store.instance_variable_get(:@store)).to be(backend),
                                                        "#{const} is not wired over BACKEND"
      end
    end

    it "config stores (profiles/tools/settings/...) also ride the same BACKEND" do
      # ConfigStore is the durable-config seam; it must share the backend so config
      # survives with execution state on one volume.
      expect(w::CONFIG_STORE.instance_variable_get(:@store)).to be(w::BACKEND)
    end

    it "selects Memory without HARNESS_DB (dev/demo default)" do
      skip "HARNESS_DB is set in this environment" unless ENV["HARNESS_DB"].to_s.empty?
      expect(w::BACKEND).to be_a(Harness::Stores::Memory)
    end

    it "exposes the recovery-relevant stores via .stores" do
      expect(w.stores.keys).to contain_exactly(:session, :task, :checkpoint, :pending, :memory)
    end
  end

  describe "command bus" do
    it "registers the turn-essential handlers" do
      %i[create_session send_message cancel_task resume_task].each do |type|
        expect(w::BUS.registered?(type)).to be(true), "missing core command #{type}"
      end
    end

    it "registers the full runtime-authoring surface (Studio/gateway writes go via the bus)" do
      %i[
        create_agent update_agent delete_agent set_agent_tools
        write_agent_file delete_agent_file restore_agent_file
        write_skill set_skill_agents
        memory_put_fact memory_forget_fact memory_add_note
        update_settings upsert_llm_provider delete_llm_provider
        upsert_mcp delete_mcp
        write_system_file delete_system_file restore_system_file
        write_data_tool delete_data_tool restore_data_tool
        import_tools import_mcp_tools
      ].each do |type|
        expect(w::BUS.registered?(type)).to be(true), "missing authoring command #{type}"
      end
    end

    # B4 (commit 2): pause_task/approve_action now come from the SHARED graph core
    # (Harness::Wiring::Graph#build_core_bus), so the deployment BUS carries them out
    # of the box — the config.ru:28-34 / serve_real.rb patch is gone.
    it "registers the /admin control commands from the shared core (no entrypoint patch)" do
      expect(w::BUS.registered?(:pause_task)).to be(true)
      expect(w::BUS.registered?(:approve_action)).to be(true)
    end
  end

  describe "agent seed (idempotent)" do
    it "seeds the Bia agent into the durable ProfileSource" do
      bia = w::PROFILE_SOURCE.fetch("bia")
      expect(bia).not_to be_nil
      expect(bia.model).to eq(Deploy::MODEL)
    end

    it "does not duplicate Bia when the seed guard runs again" do
      before = w::PROFILE_SOURCE.ids.count("bia")
      # Re-run the exact guard from deployment.rb — must be a no-op.
      unless w::PROFILE_SOURCE.fetch("bia")
        w::PROFILE_SOURCE.put(Harness::AgentProfile.build(id: "bia", model: Deploy::MODEL, provider: :deepseek))
      end
      expect(w::PROFILE_SOURCE.ids.count("bia")).to eq(before)
    end

    it "seeds the platform default_model (v2 model resolution, §10)" do
      expect(w::SETTINGS_STORE.get["default_model"]).to eq(Deploy::MODEL)
      expect(w::SETTINGS_STORE.get["default_provider"]).to eq("deepseek")
    end
  end

  describe "execution graph" do
    it "builds the Executor with the overlay tool registry (code + data-defined tools)" do
      expect(w::EXECUTOR).to be_a(Harness::Executor)
      expect(w::TOOL_REGISTRY).to be_a(Harness::OverlayToolRegistry)
    end

    it "wires the context providers, including Session and Memory" do
      classes = w::CONTEXT_PROVIDERS.map(&:class)
      expect(classes).to include(Harness::Context::Providers::Session)
      expect(classes).to include(Harness::Context::Providers::Memory)
      expect(classes).to include(Harness::Context::Providers::Prompt)
    end

    it "registers the policy builtins the profiles reference" do
      expect(w::POLICY_REGISTRY.fetch(:tool_allowlist)).to be_a(Harness::Policy::Builtin::ToolAllowlist)
      expect(w::POLICY_REGISTRY.fetch(:skill_allowlist)).to be_a(Harness::Policy::Builtin::SkillAllowlist)
      expect(w::POLICY_REGISTRY.fetch(:approval_required)).to be_a(Harness::Policy::Builtin::ApprovalRequired)
    end

    it "composes the guardrail seams (RFC-0009) onto the graph" do
      expect(w::GUARDRAILS).to be_a(Harness::Safety::Factory)
      expect(w::MIDDLEWARE).to be_a(Harness::MiddlewareStack)
    end

    it "exposes the provisioner (pack importer) for the gateway /v1/agents" do
      expect(w::PACK_IMPORTER).to be_a(Harness::PackImporter)
    end
  end
end

# frozen_string_literal: true

require "spec_helper"
require "async"

# Proves the FS/shell toolset REUSES the engine's existing approval machinery
# rather than inventing a parallel path:
#   1. the "harness-code" profile + the builtin ApprovalRequired policy mark
#      write_file/edit_file/bash (and only those) as requiring approval;
#   2. the ToolEnvelope gate consults that marking and suspends via the approval
#      coordinator, rejecting or running the tool based on the operator decision.
RSpec.describe "harness-code approval wiring" do
  describe "profile + policy engine" do
    let(:event_stream) { Harness::EventStream.new }

    let(:registry) do
      Harness::ToolRegistry.new.tap do |r|
        %w[read_file list_dir grep].each { |n| r.register(n, plugin: "harness-code") { nil } }
        %w[write_file edit_file bash].each { |n| r.register(n, side_effect: true, plugin: "harness-code") { nil } }
      end
    end

    let(:policy_registry) do
      Harness::PolicyRegistry.new.tap do |pr|
        pr.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
        pr.register(:approval_required, Harness::Policy::Builtin::ApprovalRequired)
      end
    end

    let(:profile) do
      Harness::AgentProfile.build(
        id: "harness-code", model: "fake",
        tools_allow: %w[read_file list_dir grep write_file edit_file bash],
        policies: %i[tool_allowlist approval_required],
        approvals_required: %w[write_file edit_file bash]
      )
    end

    subject(:resolution) do
      engine = Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream)
      request = Harness::Policy::PolicyRequest.new(
        profile: profile, command: nil, context: nil,
        candidate_tools: registry.entries, candidate_skills: []
      )
      engine.decide(request)
    end

    it "requires approval for exactly the write/shell tools" do
      expect(resolution.requires_approval).to contain_exactly("write_file", "edit_file", "bash")
    end

    it "still allows the full toolset (approval is a gate, not a deny)" do
      expect(resolution.allowed_tools.map(&:name))
        .to contain_exactly("read_file", "list_dir", "grep", "write_file", "edit_file", "bash")
    end

    it "marks the write/shell tools as side-effecting in the registry" do
      expect(registry.side_effect?("write_file")).to be(true)
      expect(registry.side_effect?("read_file")).to be(false)
    end
  end

  describe "ToolEnvelope approval gate" do
    let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }
    let(:profile) { Harness::AgentProfile.build(id: "harness-code", model: "fake") }
    let(:state) do
      Harness::TurnState.new(task: task, profile: profile, turn: 1, message: "go").tap do |s|
        s.requires_approval = %w[write_file]
        s.approval_coordinator = coordinator
        s.actor = Object.new
      end
    end

    let(:tool) do
      Class.new do
        attr_reader :calls
        def initialize = (@calls = [])
        def name = "write_file"
        def call(args) = (@calls << args; { path: "x", status: "written" })
      end.new
    end

    let(:tool_registry) { instance_double(Harness::ToolRegistry, side_effect?: true) }
    let(:checkpoint_store) { double("checkpoint_store", record_side_effect: nil) }

    let(:envelope) do
      Harness::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
                                      tool_registry: tool_registry, timeout: 5)
    end

    context "when the operator rejects" do
      let(:coordinator) do
        Class.new { def request_approval(**) = "rejected" }.new
      end

      it "returns an error to the model and never runs the tool" do
        expect(envelope.call({ "path" => "a.txt" })).to eq({ error: "rejected by operator" })
        expect(tool.calls).to be_empty
      end
    end

    context "when the operator approves" do
      let(:coordinator) do
        Class.new { def request_approval(**) = "approved" }.new
      end

      it "runs the tool and records the side-effect" do
        result = nil
        Sync { result = envelope.call({ "path" => "a.txt" }) }
        expect(result).to eq({ path: "x", status: "written" })
        expect(tool.calls).to eq([{ "path" => "a.txt" }])
        expect(checkpoint_store).to have_received(:record_side_effect)
      end
    end
  end
end

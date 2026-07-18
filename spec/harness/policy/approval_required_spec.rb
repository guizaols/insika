# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Policy::Builtin::ApprovalRequired do
  subject(:policy) { described_class.new }

  def request_for(approvals_required)
    profile = Harness::AgentProfile.build(id: "a", model: "m", approvals_required: approvals_required)
    Harness::Policy::PolicyRequest.new(profile: profile, command: nil, context: nil,
                                       candidate_tools: [], candidate_skills: [])
  end

  it "approvals_required nil -> requires_approval empty (none require it)" do
    d = policy.decide(request_for(nil))
    expect(d.verdict).to eq(:allow)
    expect(d.requires_approval).to eq([])
  end

  it "approvals_required [names] -> those require approval (string)" do
    d = policy.decide(request_for(%i[charge refund]))
    expect(d.requires_approval).to eq(%w[charge refund])
  end

  it "never denies nor restricts tools/skills (only attaches requires_approval)" do
    d = policy.decide(request_for(["charge"]))
    expect(d.allow_tools).to be_nil
    expect(d.deny_tools).to eq([])
  end

  describe "aggregation in the Engine" do
    let(:registry) do
      reg = Harness::PolicyRegistry.new
      reg.register(:approval_required, described_class)
      reg.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
      reg
    end
    let(:engine) { Harness::Policy::Engine.new(policy_registry: registry, event_stream: SpyEventStream.new) }

    it "Resolution.requires_approval gathers the policy names" do
      profile = Harness::AgentProfile.build(
        id: "a", model: "m", policies: %i[tool_allowlist approval_required],
        approvals_required: %w[charge]
      )
      req = Harness::Policy::PolicyRequest.new(
        profile: profile, command: nil, context: nil,
        candidate_tools: [], candidate_skills: []
      )
      resolution = engine.decide(req)
      expect(resolution.requires_approval).to eq(%w[charge])
    end
  end
end

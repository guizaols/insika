# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Insika::Policy builtins" do
  # Entry like ToolRegistry::Entry (metadata-based, doc 06 §2).
  Entry = Struct.new(:name, :metadata)
  def entry(name, optional: false, group: nil) = Entry.new(name, { optional: optional, group: group })
  Cmd = Struct.new(:type, :payload)

  def profile(**over)
    Insika::AgentProfile.build(**{ id: "a", model: "m" }.merge(over))
  end

  def request(profile:, tools: [], command: nil, skills: [])
    Insika::Policy::PolicyRequest.new(profile: profile, command: command, context: nil,
                                       candidate_tools: tools, candidate_skills: skills)
  end

  describe Insika::Policy::Builtin::ToolAllowlist do
    subject(:policy) { described_class.new }

    it "required always gets in (allow nil, deny [])" do
      d = policy.decide(request(profile: profile(tools_allow: nil), tools: [entry("a")]))
      expect(d.deny_tools).to eq([])
      expect(d.allow_tools).to be_nil
    end

    it "optional without opt-in -> deny" do
      d = policy.decide(request(profile: profile(tools_allow: nil), tools: [entry("b", optional: true)]))
      expect(d.deny_tools).to include("b")
    end

    it "optional with opt-in -> not denied" do
      d = policy.decide(request(profile: profile(tools_allow: ["b"]), tools: [entry("b", optional: true)]))
      expect(d.deny_tools).not_to include("b")
      expect(d.allow_tools).to eq(["b"])
    end

    it "non-empty allow = final set (no merge)" do
      d = policy.decide(request(profile: profile(tools_allow: ["a"]),
                                tools: [entry("a"), entry("b")]))
      expect(d.allow_tools).to eq(["a"])
    end

    it "deny always wins" do
      d = policy.decide(request(profile: profile(tools_allow: ["a"], tools_deny: ["a"]),
                                tools: [entry("a")]))
      expect(d.deny_tools).to include("a")
    end

    it "allow [] -> empty set (D6, intentional divergence from Phase 0)" do
      d = policy.decide(request(profile: profile(tools_allow: []), tools: [entry("a")]))
      expect(d.allow_tools).to eq([])
    end

    it "is pure (2 calls -> same result)" do
      req = request(profile: profile(tools_allow: ["a"]), tools: [entry("a")])
      expect(policy.decide(req)).to eq(policy.decide(req))
    end

    # Phase 7/D4/F5 (Stage C): tools_allow_groups expands to the group's tools.
    describe "allowlist by group (tools_allow_groups)" do
      let(:tools) do
        [entry("search", group: "b2b"), entry("finalize", group: "b2b"),
         entry("menu", group: "default"), entry("calc", group: nil)]
      end

      it "expands the group to the names of that group's tools" do
        d = policy.decide(request(profile: profile(tools_allow_groups: ["b2b"]), tools: tools))
        expect(d.allow_tools).to contain_exactly("search", "finalize")
      end

      it "UNIONs tools_allow (names) with tools_allow_groups (groups)" do
        d = policy.decide(request(profile: profile(tools_allow: ["calc"], tools_allow_groups: ["b2b"]), tools: tools))
        expect(d.allow_tools).to contain_exactly("calc", "search", "finalize")
      end

      it "both nil = all (allow_tools nil — parity)" do
        d = policy.decide(request(profile: profile(tools_allow: nil, tools_allow_groups: nil), tools: tools))
        expect(d.allow_tools).to be_nil
      end

      it "tools_deny beats the group expansion" do
        d = policy.decide(request(profile: profile(tools_allow_groups: ["b2b"], tools_deny: ["finalize"]), tools: tools))
        expect(d.allow_tools).to include("search", "finalize") # allow expands…
        expect(d.deny_tools).to include("finalize")            # …but deny wins in the Engine
      end

      it "non-existent group -> empty set (whitelist with no match)" do
        d = policy.decide(request(profile: profile(tools_allow_groups: ["fantasma"]), tools: tools))
        expect(d.allow_tools).to eq([])
      end

      it "tools_allow=[] + groups=['b2b'] -> only the group's (union with ∅)" do
        d = policy.decide(request(profile: profile(tools_allow: [], tools_allow_groups: ["b2b"]), tools: tools))
        expect(d.allow_tools).to contain_exactly("search", "finalize")
      end
    end
  end

  describe Insika::Policy::Builtin::SkillAllowlist do
    subject(:policy) { described_class.new }

    it "nil -> allow_skills nil" do
      expect(policy.decide(request(profile: profile(skills: nil))).allow_skills).to be_nil
    end

    it "[] -> allow_skills []" do
      expect(policy.decide(request(profile: profile(skills: []))).allow_skills).to eq([])
    end

    it "[names] -> allow_skills names" do
      expect(policy.decide(request(profile: profile(skills: %w[x y]))).allow_skills).to eq(%w[x y])
    end
  end

  describe Insika::Policy::Builtin::WorkflowAllowlist do
    subject(:policy) { described_class.new }

    it "allow when the workflow is in the allowlist" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "w1" })
      d = policy.decide(request(profile: profile(workflows_allow: ["w1"]), command: cmd))
      expect(d.verdict).to eq(:allow)
    end

    it "deny when the workflow is not present (list without the name)" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "w2" })
      d = policy.decide(request(profile: profile(workflows_allow: ["w1"]), command: cmd))
      expect(d.verdict).to eq(:deny)
      expect(d.reason).to include("w2")
    end

    it "deny when workflows_allow == []" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "w1" })
      expect(policy.decide(request(profile: profile(workflows_allow: []), command: cmd)).verdict).to eq(:deny)
    end

    it "neutral (allow) for a command that is not a workflow, or nil" do
      cmd = Cmd.new(:send_message, {})
      expect(policy.decide(request(profile: profile(workflows_allow: []), command: cmd)).verdict).to eq(:allow)
      expect(policy.decide(request(profile: profile(workflows_allow: []), command: nil)).verdict).to eq(:allow)
    end

    it "allow when workflows_allow nil (no restriction)" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "qualquer" })
      expect(policy.decide(request(profile: profile(workflows_allow: nil), command: cmd)).verdict).to eq(:allow)
    end
  end

  describe Insika::Policy::Decision do
    it ".allow has verdict :allow and reason nil" do
      d = described_class.allow(allow_tools: ["a"])
      expect([d.verdict, d.reason]).to eq([:allow, nil])
    end

    it ".deny has verdict :deny and reason" do
      d = described_class.deny(reason: "x")
      expect([d.verdict, d.reason]).to eq([:deny, "x"])
    end
  end
end

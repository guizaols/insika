# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Harness::Policy builtins" do
  # Entry como o ToolRegistry::Entry (metadata-based, doc 06 §2).
  Entry = Struct.new(:name, :metadata)
  def entry(name, optional: false, group: nil) = Entry.new(name, { optional: optional, group: group })
  Cmd = Struct.new(:type, :payload)

  def profile(**over)
    Harness::AgentProfile.build(**{ id: "a", model: "m" }.merge(over))
  end

  def request(profile:, tools: [], command: nil, skills: [])
    Harness::Policy::PolicyRequest.new(profile: profile, command: command, context: nil,
                                       candidate_tools: tools, candidate_skills: skills)
  end

  describe Harness::Policy::Builtin::ToolAllowlist do
    subject(:policy) { described_class.new }

    it "required sempre entra (allow nil, deny [])" do
      d = policy.decide(request(profile: profile(tools_allow: nil), tools: [entry("a")]))
      expect(d.deny_tools).to eq([])
      expect(d.allow_tools).to be_nil
    end

    it "optional sem opt-in -> deny" do
      d = policy.decide(request(profile: profile(tools_allow: nil), tools: [entry("b", optional: true)]))
      expect(d.deny_tools).to include("b")
    end

    it "optional com opt-in -> não negada" do
      d = policy.decide(request(profile: profile(tools_allow: ["b"]), tools: [entry("b", optional: true)]))
      expect(d.deny_tools).not_to include("b")
      expect(d.allow_tools).to eq(["b"])
    end

    it "allow não-vazia = conjunto final (sem merge)" do
      d = policy.decide(request(profile: profile(tools_allow: ["a"]),
                                tools: [entry("a"), entry("b")]))
      expect(d.allow_tools).to eq(["a"])
    end

    it "deny sempre vence" do
      d = policy.decide(request(profile: profile(tools_allow: ["a"], tools_deny: ["a"]),
                                tools: [entry("a")]))
      expect(d.deny_tools).to include("a")
    end

    it "allow [] -> conjunto vazio (D6, divergência intencional da Fase 0)" do
      d = policy.decide(request(profile: profile(tools_allow: []), tools: [entry("a")]))
      expect(d.allow_tools).to eq([])
    end

    it "é pura (2 chamadas -> mesmo resultado)" do
      req = request(profile: profile(tools_allow: ["a"]), tools: [entry("a")])
      expect(policy.decide(req)).to eq(policy.decide(req))
    end

    # Fase 7/D4/F5 (Etapa C): tools_allow_groups expande p/ as tools do grupo.
    describe "allowlist por grupo (tools_allow_groups)" do
      let(:tools) do
        [entry("search", group: "b2b"), entry("finalize", group: "b2b"),
         entry("menu", group: "default"), entry("calc", group: nil)]
      end

      it "expande o grupo p/ os nomes das tools daquele grupo" do
        d = policy.decide(request(profile: profile(tools_allow_groups: ["b2b"]), tools: tools))
        expect(d.allow_tools).to contain_exactly("search", "finalize")
      end

      it "UNE tools_allow (nomes) com tools_allow_groups (grupos)" do
        d = policy.decide(request(profile: profile(tools_allow: ["calc"], tools_allow_groups: ["b2b"]), tools: tools))
        expect(d.allow_tools).to contain_exactly("calc", "search", "finalize")
      end

      it "ambas nil = todas (allow_tools nil — paridade)" do
        d = policy.decide(request(profile: profile(tools_allow: nil, tools_allow_groups: nil), tools: tools))
        expect(d.allow_tools).to be_nil
      end

      it "tools_deny vence a expansão de grupo" do
        d = policy.decide(request(profile: profile(tools_allow_groups: ["b2b"], tools_deny: ["finalize"]), tools: tools))
        expect(d.allow_tools).to include("search", "finalize") # allow expande…
        expect(d.deny_tools).to include("finalize")            # …mas deny vence no Engine
      end

      it "grupo inexistente -> conjunto vazio (whitelist sem match)" do
        d = policy.decide(request(profile: profile(tools_allow_groups: ["fantasma"]), tools: tools))
        expect(d.allow_tools).to eq([])
      end

      it "tools_allow=[] + groups=['b2b'] -> só as do grupo (union com ∅)" do
        d = policy.decide(request(profile: profile(tools_allow: [], tools_allow_groups: ["b2b"]), tools: tools))
        expect(d.allow_tools).to contain_exactly("search", "finalize")
      end
    end
  end

  describe Harness::Policy::Builtin::SkillAllowlist do
    subject(:policy) { described_class.new }

    it "nil -> allow_skills nil" do
      expect(policy.decide(request(profile: profile(skills: nil))).allow_skills).to be_nil
    end

    it "[] -> allow_skills []" do
      expect(policy.decide(request(profile: profile(skills: []))).allow_skills).to eq([])
    end

    it "[names] -> allow_skills nomes" do
      expect(policy.decide(request(profile: profile(skills: %w[x y]))).allow_skills).to eq(%w[x y])
    end
  end

  describe Harness::Policy::Builtin::WorkflowAllowlist do
    subject(:policy) { described_class.new }

    it "allow quando o workflow está na allowlist" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "w1" })
      d = policy.decide(request(profile: profile(workflows_allow: ["w1"]), command: cmd))
      expect(d.verdict).to eq(:allow)
    end

    it "deny quando o workflow não está (lista sem o nome)" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "w2" })
      d = policy.decide(request(profile: profile(workflows_allow: ["w1"]), command: cmd))
      expect(d.verdict).to eq(:deny)
      expect(d.reason).to include("w2")
    end

    it "deny quando workflows_allow == []" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "w1" })
      expect(policy.decide(request(profile: profile(workflows_allow: []), command: cmd)).verdict).to eq(:deny)
    end

    it "neutra (allow) para command que não é workflow, ou nil" do
      cmd = Cmd.new(:send_message, {})
      expect(policy.decide(request(profile: profile(workflows_allow: []), command: cmd)).verdict).to eq(:allow)
      expect(policy.decide(request(profile: profile(workflows_allow: []), command: nil)).verdict).to eq(:allow)
    end

    it "allow quando workflows_allow nil (sem restrição)" do
      cmd = Cmd.new(:trigger_workflow, { workflow: "qualquer" })
      expect(policy.decide(request(profile: profile(workflows_allow: nil), command: cmd)).verdict).to eq(:allow)
    end
  end

  describe Harness::Policy::Decision do
    it ".allow tem verdict :allow e reason nil" do
      d = described_class.allow(allow_tools: ["a"])
      expect([d.verdict, d.reason]).to eq([:allow, nil])
    end

    it ".deny tem verdict :deny e reason" do
      d = described_class.deny(reason: "x")
      expect([d.verdict, d.reason]).to eq([:deny, "x"])
    end
  end
end

# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Policy::Engine do
  let(:event_stream) { SpyEventStream.new } # spec/support/fakes.rb

  # Candidate tools/skills as objects with #name.
  Tool = Struct.new(:name)
  SkillC = Struct.new(:name)

  # Policy stub that returns a fixed Decision (and records whether it was called).
  def policy(decision, spy: nil)
    Class.new(Insika::Policy::Base) do
      define_method(:decide) do |_req|
        spy&.call
        decision
      end
    end.new
  end

  def profile(policies)
    Insika::AgentProfile.build(id: "a", model: "m", policies: policies)
  end

  def request(policies, tools: [], skills: [])
    Insika::Policy::PolicyRequest.new(
      profile: profile(policies), command: nil, context: nil,
      candidate_tools: tools, candidate_skills: skills
    )
  end

  def engine(registry)
    described_class.new(policy_registry: registry, event_stream: event_stream)
  end

  D = Insika::Policy::Decision

  it "disjoint allows -> empty intersection (not an error)" do
    reg = { "A" => policy(D.allow(allow_tools: ["x"])), "B" => policy(D.allow(allow_tools: ["y"])) }
    res = engine(reg).decide(request(%w[A B], tools: [Tool.new("x"), Tool.new("y")]))
    expect(res.allowed_tools).to eq([])
  end

  it "allow nil does not enter the intersection" do
    reg = { "A" => policy(D.allow(allow_tools: nil)), "B" => policy(D.allow(allow_tools: %w[a b])) }
    res = engine(reg).decide(request(%w[A B], tools: [Tool.new("a"), Tool.new("b")]))
    expect(res.allowed_tools.map(&:name)).to contain_exactly("a", "b")
  end

  it "deny beats allow" do
    reg = { "A" => policy(D.allow(allow_tools: %w[a b])), "B" => policy(D.allow(allow_tools: %w[a b], deny_tools: ["a"])) }
    res = engine(reg).decide(request(%w[A B], tools: [Tool.new("a"), Tool.new("b")]))
    expect(res.allowed_tools.map(&:name)).to eq(["b"])
  end

  it "first deny short-circuits: next policy does not run; audit up to the deny" do
    called3 = false
    reg = {
      "1" => policy(D.allow),
      "2" => policy(D.deny(reason: "negado")),
      "3" => policy(D.allow, spy: -> { called3 = true })
    }
    expect { engine(reg).decide(request(%w[1 2 3])) }.to raise_error(Insika::PolicyDenied)
    expect(called3).to be(false)
  end

  it "emits :policy_denied before the raise" do
    reg = { "2" => policy(D.deny(reason: "negado")) }
    expect { engine(reg).decide(request(["2"])) }.to raise_error(Insika::PolicyDenied)
    ev = event_stream.events.find { |e| e.type == :policy_denied }
    expect(ev.data).to include(policy: "2", reason: "negado")
  end

  it "full audit with 3 allows in order" do
    reg = { "A" => policy(D.allow), "B" => policy(D.allow), "C" => policy(D.allow) }
    res = engine(reg).decide(request(%w[A B C]))
    expect(res.audit.map { |a| a[:policy] }).to eq(%w[A B C])
    expect(res.audit.map { |a| a[:verdict] }).to all(eq(:allow))
  end

  it "fail-closed: a policy that raises -> PolicyDenied 'policy crash: RuntimeError'" do
    crashing = Class.new(Insika::Policy::Base) do
      def decide(_req) = raise "boom"
    end.new
    expect { engine({ "X" => crashing }).decide(request(["X"])) }
      .to raise_error(Insika::PolicyDenied) { |e| expect(e.reason).to include("policy crash: RuntimeError") }
  end

  it "fail-closed: name not registered -> deny" do
    expect { engine({}).decide(request(["missing"])) }.to raise_error(Insika::PolicyDenied)
  end

  it "empty policies -> all candidates, empty audit" do
    res = engine({}).decide(request([], tools: [Tool.new("a"), Tool.new("b")]))
    expect(res.allowed_tools.map(&:name)).to contain_exactly("a", "b")
    expect(res.audit).to eq([])
  end

  it "evaluation order follows profile.policies (not the registry)" do
    order = []
    reg = {
      "A" => policy(D.allow, spy: -> { order << "A" }),
      "B" => policy(D.allow, spy: -> { order << "B" })
    }
    engine(reg).decide(request(%w[B A])) # profile asks for B before A
    expect(order).to eq(%w[B A])
  end

  # The end-to-end shape of the bug this guards: the engine runs only the
  # policies the profile names, so a declared allowlist with `policies: []`
  # used to resolve to EVERY candidate tool.
  describe "a declared tools_allow enforces without naming the policy" do
    ToolEntry = Struct.new(:name, :metadata)

    def real_registry
      { "tool_allowlist" => Insika::Policy::Builtin::ToolAllowlist.new }
    end

    def allowlist_request(**over)
      Insika::Policy::PolicyRequest.new(
        profile: Insika::AgentProfile.build(id: "a", model: "m", policies: [], **over),
        command: nil, context: nil,
        candidate_tools: [ToolEntry.new("x", { optional: false, group: nil }),
                          ToolEntry.new("y", { optional: false, group: nil })],
        candidate_skills: []
      )
    end

    it "resolves to exactly the allowed tool, not every candidate" do
      res = engine(real_registry).decide(allowlist_request(tools_allow: ["x"]))
      expect(res.allowed_tools.map(&:name)).to eq(["x"])
      expect(res.audit.map { |a| a[:policy] }).to eq(["tool_allowlist"])
    end

    it "honors a declared tools_deny the same way" do
      res = engine(real_registry).decide(allowlist_request(tools_deny: ["y"]))
      expect(res.allowed_tools.map(&:name)).to eq(["x"])
    end
  end

  it "aggregates skills (intersection/union) analogous to tools" do
    reg = { "A" => policy(D.allow(allow_skills: %w[s1 s2])), "B" => policy(D.allow(allow_skills: %w[s2])) }
    res = engine(reg).decide(request(%w[A B], skills: [SkillC.new("s1"), SkillC.new("s2")]))
    expect(res.allowed_skills.map(&:name)).to eq(["s2"])
  end
end

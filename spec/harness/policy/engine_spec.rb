# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Policy::Engine do
  let(:event_stream) { SpyEventStream.new } # spec/support/fakes.rb

  # Tools/skills candidatos como objetos com #name.
  Tool = Struct.new(:name)
  SkillC = Struct.new(:name)

  # Policy stub que devolve uma Decision fixa (e grava se foi chamada).
  def policy(decision, spy: nil)
    Class.new(Harness::Policy::Base) do
      define_method(:decide) do |_req|
        spy&.call
        decision
      end
    end.new
  end

  def profile(policies)
    Harness::AgentProfile.build(id: "a", model: "m", policies: policies)
  end

  def request(policies, tools: [], skills: [])
    Harness::Policy::PolicyRequest.new(
      profile: profile(policies), command: nil, context: nil,
      candidate_tools: tools, candidate_skills: skills
    )
  end

  def engine(registry)
    described_class.new(policy_registry: registry, event_stream: event_stream)
  end

  D = Harness::Policy::Decision

  it "allows disjuntos -> interseção vazia (não erro)" do
    reg = { "A" => policy(D.allow(allow_tools: ["x"])), "B" => policy(D.allow(allow_tools: ["y"])) }
    res = engine(reg).decide(request(%w[A B], tools: [Tool.new("x"), Tool.new("y")]))
    expect(res.allowed_tools).to eq([])
  end

  it "allow nil não entra na interseção" do
    reg = { "A" => policy(D.allow(allow_tools: nil)), "B" => policy(D.allow(allow_tools: %w[a b])) }
    res = engine(reg).decide(request(%w[A B], tools: [Tool.new("a"), Tool.new("b")]))
    expect(res.allowed_tools.map(&:name)).to contain_exactly("a", "b")
  end

  it "deny vence allow" do
    reg = { "A" => policy(D.allow(allow_tools: %w[a b])), "B" => policy(D.allow(allow_tools: %w[a b], deny_tools: ["a"])) }
    res = engine(reg).decide(request(%w[A B], tools: [Tool.new("a"), Tool.new("b")]))
    expect(res.allowed_tools.map(&:name)).to eq(["b"])
  end

  it "primeiro deny interrompe: policy seguinte não roda; audit até o deny" do
    called3 = false
    reg = {
      "1" => policy(D.allow),
      "2" => policy(D.deny(reason: "negado")),
      "3" => policy(D.allow, spy: -> { called3 = true })
    }
    expect { engine(reg).decide(request(%w[1 2 3])) }.to raise_error(Harness::PolicyDenied)
    expect(called3).to be(false)
  end

  it "emite :policy_denied antes do raise" do
    reg = { "2" => policy(D.deny(reason: "negado")) }
    expect { engine(reg).decide(request(["2"])) }.to raise_error(Harness::PolicyDenied)
    ev = event_stream.events.find { |e| e.type == :policy_denied }
    expect(ev.data).to include(policy: "2", reason: "negado")
  end

  it "audit completo com 3 allows na ordem" do
    reg = { "A" => policy(D.allow), "B" => policy(D.allow), "C" => policy(D.allow) }
    res = engine(reg).decide(request(%w[A B C]))
    expect(res.audit.map { |a| a[:policy] }).to eq(%w[A B C])
    expect(res.audit.map { |a| a[:verdict] }).to all(eq(:allow))
  end

  it "fail-closed: policy que levanta -> PolicyDenied 'policy crash: RuntimeError'" do
    crashing = Class.new(Harness::Policy::Base) do
      def decide(_req) = raise "boom"
    end.new
    expect { engine({ "X" => crashing }).decide(request(["X"])) }
      .to raise_error(Harness::PolicyDenied) { |e| expect(e.reason).to include("policy crash: RuntimeError") }
  end

  it "fail-closed: nome não registrado -> deny" do
    expect { engine({}).decide(request(["ausente"])) }.to raise_error(Harness::PolicyDenied)
  end

  it "policies vazio -> todas as candidatas, audit vazio" do
    res = engine({}).decide(request([], tools: [Tool.new("a"), Tool.new("b")]))
    expect(res.allowed_tools.map(&:name)).to contain_exactly("a", "b")
    expect(res.audit).to eq([])
  end

  it "ordem de avaliação segue profile.policies (não o registry)" do
    order = []
    reg = {
      "A" => policy(D.allow, spy: -> { order << "A" }),
      "B" => policy(D.allow, spy: -> { order << "B" })
    }
    engine(reg).decide(request(%w[B A])) # perfil pede B antes de A
    expect(order).to eq(%w[B A])
  end

  it "agrega skills (interseção/união) análogo a tools" do
    reg = { "A" => policy(D.allow(allow_skills: %w[s1 s2])), "B" => policy(D.allow(allow_skills: %w[s2])) }
    res = engine(reg).decide(request(%w[A B], skills: [SkillC.new("s1"), SkillC.new("s2")]))
    expect(res.allowed_skills.map(&:name)).to eq(["s2"])
  end
end

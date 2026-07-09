# frozen_string_literal: true

require "spec_helper"
require "async"

RSpec.describe Harness::ContextBuilder do
  let(:event_stream) { SpyEventStream.new } # de spec/support/fakes.rb

  # Provider fake roteirizável (implementa o contrato de ContextProvider).
  def provider(id:, fragments: [], required: false, enabled: true, raises: nil, sleep_for: nil)
    Class.new(Harness::ContextProvider) do
      define_method(:id) { id }
      define_method(:required?) { required }
      define_method(:enabled_for?) { |_p| enabled }
      define_method(:call) do |_req|
        raise raises if raises

        Async::Task.current.sleep(sleep_for) if sleep_for
        fragments
      end
    end.new
  end

  def frag(content, placement: :system, priority: 50, source: "p", tokens: nil, pinned: false)
    Harness::ContextFragment.build(content: content, placement: placement, priority: priority,
                                   source: source, tokens: tokens, pinned: pinned)
  end

  def profile(context_providers: nil, budget: 8_000, provider_timeout: 5)
    Harness::AgentProfile.build(id: "a", model: "m", context_providers: context_providers,
                                limits: { context_budget: budget, provider_timeout: provider_timeout })
  end

  def build(providers, prof = profile)
    request = Harness::ContextRequest.new(session: nil, message: "oi", profile: prof,
                                          tenant: nil, vars: {}, checkpoint: nil)
    builder = described_class.new(providers: providers, event_stream: event_stream)
    Sync { builder.call(request) }
  end

  describe "seleção (allowlist D6)" do
    let(:pa) { provider(id: "A", fragments: [frag("a", source: "A")]) }
    let(:pb) { provider(id: "B", fragments: [frag("b", source: "B")]) }

    it "nil -> todos rodam" do
      pkg = build([pa, pb], profile(context_providers: nil))
      expect(pkg.system).to eq("a\n\nb")
    end

    it "[] -> nenhum roda; pacote vazio válido" do
      pkg = build([pa, pb], profile(context_providers: []))
      expect(pkg.system).to eq("")
      expect(pkg.history).to eq([])
      expect(pkg.tool_context).to be_nil
      expect(pkg.budget[:used]).to eq(0)
    end

    it "[names] -> só o nomeado roda" do
      pkg = build([pa, pb], profile(context_providers: ["A"]))
      expect(pkg.system).to eq("a")
    end

    it "enabled_for? falso -> não roda mesmo com allowlist nil" do
      off = provider(id: "C", fragments: [frag("c", source: "C")], enabled: false)
      pkg = build([pa, off])
      expect(pkg.system).to eq("a")
    end
  end

  describe "agrupamento e ordem canônica" do
    it "agrupa por placement no campo certo" do
      p = provider(id: "P", fragments: [
                     frag("SYS", placement: :system, source: "P"),
                     frag({ role: "user", content: "hi" }, placement: :history, source: "P"),
                     frag("TOOL", placement: :tool_context, source: "P")
                   ])
      pkg = build([p])
      expect(pkg.system).to eq("SYS")
      expect(pkg.history).to eq([{ role: "user", content: "hi" }])
      expect(pkg.tool_context).to eq("TOOL")
    end

    it "system em priority DESC, join com \\n\\n" do
      p = provider(id: "P", fragments: [
                     frag("P40", priority: 40, source: "P"),
                     frag("P100", priority: 100, source: "P"),
                     frag("P80", priority: 80, source: "P")
                   ])
      expect(build([p]).system).to eq("P100\n\nP80\n\nP40")
    end

    it "empate de priority: source alfabético; determinístico ao repetir" do
      p = provider(id: "P", fragments: [
                     frag("fromB", priority: 80, source: "B"),
                     frag("fromA", priority: 80, source: "A")
                   ])
      first = build([p]).system
      second = build([p]).system
      expect(first).to eq("fromA\n\nfromB")
      expect(second).to eq(first)
    end

    it "history em ordem cronológica (produção), priority não reordena" do
      p = provider(id: "P", fragments: [
                     frag({ n: 1 }, placement: :history, priority: 10, source: "P"),
                     frag({ n: 2 }, placement: :history, priority: 90, source: "P"),
                     frag({ n: 3 }, placement: :history, priority: 50, source: "P")
                   ])
      expect(build([p]).history).to eq([{ n: 1 }, { n: 2 }, { n: 3 }])
    end
  end

  describe "estimativa de tokens (L3)" do
    it "preenche tokens nil via estimator; não sobrescreve tokens informado" do
      p = provider(id: "P", fragments: [
                     frag("12345678", source: "P"),         # 8 chars -> ceil(8/4)=2
                     frag("x", source: "P", tokens: 999)
                   ])
      pkg = build([p])
      tokens = pkg.fragments.map(&:tokens)
      expect(tokens).to include(2, 999)
    end
  end

  describe "orçamento (D8, L1)" do
    it "corta o menor priority primeiro e para exatamente quando cabe" do
      p = provider(id: "P", fragments: [
                     frag("lo", priority: 10, source: "LO", tokens: 40),
                     frag("mid", priority: 20, source: "MID", tokens: 40),
                     frag("hi", priority: 30, source: "HI", tokens: 40)
                   ])
      pkg = build([p], profile(budget: 100)) # used 120 -> corta 1 (o de 40 tokens, priority 10)
      expect(pkg.budget[:used]).to eq(80)
      expect(pkg.budget[:evicted]).to eq(["LO"])
      expect(pkg.fragments.map(&:source)).to contain_exactly("MID", "HI")
    end

    it "empate de priority: corta o produzido antes (índice estável)" do
      p = provider(id: "P", fragments: [
                     frag("first", priority: 50, source: "FIRST", tokens: 60),
                     frag("second", priority: 50, source: "SECOND", tokens: 60)
                   ])
      pkg = build([p], profile(budget: 100)) # corta 1 dos dois iguais -> o primeiro
      expect(pkg.budget[:evicted]).to eq(["FIRST"])
    end

    it "pinned é incortável (sobrevive mesmo com priority baixa)" do
      p = provider(id: "P", fragments: [
                     frag("id", priority: 1, source: "PIN", tokens: 40, pinned: true),
                     frag("big", priority: 99, source: "BIG", tokens: 40)
                   ])
      pkg = build([p], profile(budget: 50)) # corta o não-pinned (BIG), pinned fica
      expect(pkg.fragments.map(&:source)).to eq(["PIN"])
      expect(pkg.budget[:evicted]).to eq(["BIG"])
    end

    it "só pinned excedendo o cap -> ContextError" do
      p = provider(id: "P", fragments: [frag("id", source: "PIN", tokens: 40, pinned: true)])
      expect { build([p], profile(budget: 30)) }.to raise_error(Harness::ContextError, /insolúvel/)
    end

    it "evicção emite 1 :provider_warning agregado" do
      p = provider(id: "P", fragments: [
                     frag("lo", priority: 10, source: "LO", tokens: 80),
                     frag("hi", priority: 90, source: "HI", tokens: 40)
                   ])
      build([p], profile(budget: 100))
      warnings = event_stream.events.select { |e| e.type == :provider_warning }
      expect(warnings.size).to eq(1)
      expect(warnings.first.data[:provider]).to eq("ContextBuilder")
    end

    it "used == cap não dispara evicção" do
      p = provider(id: "P", fragments: [frag("x", source: "P", tokens: 100)])
      pkg = build([p], profile(budget: 100))
      expect(pkg.budget[:evicted]).to eq([])
      expect(event_stream.events).to be_empty
    end
  end

  describe "erros e degradação de provider (doc 04 §6)" do
    it "opcional que falha -> :provider_warning + resto montado" do
      bad = provider(id: "BAD", raises: RuntimeError.new("caiu"))
      good = provider(id: "GOOD", fragments: [frag("ok", source: "GOOD")])
      pkg = build([bad, good])
      expect(pkg.system).to eq("ok")
      w = event_stream.events.find { |e| e.type == :provider_warning }
      expect(w.data).to include(provider: "BAD", message: "caiu")
    end

    it "opcional que dorme além do timeout -> warning, turno segue" do
      slow = provider(id: "SLOW", sleep_for: 0.2)
      good = provider(id: "GOOD", fragments: [frag("ok", source: "GOOD")])
      pkg = build([slow, good], profile(provider_timeout: 0.05))
      expect(pkg.system).to eq("ok")
      expect(event_stream.events.map { |e| e.data[:provider] }).to include("SLOW")
    end

    it "required que falha -> ContextError com provider" do
      req = provider(id: "REQ", required: true, raises: RuntimeError.new("boom"))
      expect { build([req]) }.to raise_error(Harness::ContextError) { |e| expect(e.provider).to eq("REQ") }
    end

    it "required lento -> ContextError" do
      req = provider(id: "REQ", required: true, sleep_for: 0.2)
      expect { build([req], profile(provider_timeout: 0.05)) }.to raise_error(Harness::ContextError)
    end

    it "provider que devolve nil é tratado como []" do
      nily = provider(id: "NIL", fragments: nil)
      good = provider(id: "GOOD", fragments: [frag("ok", source: "GOOD")])
      expect(build([nily, good]).system).to eq("ok")
    end
  end
end

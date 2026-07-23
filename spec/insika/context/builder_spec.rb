# frozen_string_literal: true

require "spec_helper"
require "async"

RSpec.describe Insika::ContextBuilder do
  let(:event_stream) { SpyEventStream.new } # from spec/support/fakes.rb

  # Scriptable fake provider (implements the ContextProvider contract).
  def provider(id:, fragments: [], required: false, enabled: true, raises: nil, sleep_for: nil)
    Class.new(Insika::ContextProvider) do
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
    Insika::ContextFragment.build(content: content, placement: placement, priority: priority,
                                   source: source, tokens: tokens, pinned: pinned)
  end

  def profile(context_providers: nil, budget: 8_000, provider_timeout: 5)
    Insika::AgentProfile.build(id: "a", model: "m", context_providers: context_providers,
                                limits: { context_budget: budget, provider_timeout: provider_timeout })
  end

  def build(providers, prof = profile, hooks: Insika::Hooks.new)
    request = Insika::ContextRequest.new(session: nil, message: "oi", profile: prof,
                                          tenant: nil, vars: {}, checkpoint: nil)
    builder = described_class.new(providers: providers, event_stream: event_stream, hooks: hooks)
    Sync { builder.call(request) }
  end

  describe "selection (allowlist D6)" do
    let(:pa) { provider(id: "A", fragments: [frag("a", source: "A")]) }
    let(:pb) { provider(id: "B", fragments: [frag("b", source: "B")]) }

    it "nil -> all run" do
      pkg = build([pa, pb], profile(context_providers: nil))
      expect(pkg.system).to eq("a\n\nb")
    end

    it "[] -> none run; valid empty package" do
      pkg = build([pa, pb], profile(context_providers: []))
      expect(pkg.system).to eq("")
      expect(pkg.history).to eq([])
      expect(pkg.tool_context).to be_nil
      expect(pkg.budget[:used]).to eq(0)
    end

    it "[names] -> only the named one runs" do
      pkg = build([pa, pb], profile(context_providers: ["A"]))
      expect(pkg.system).to eq("a")
    end

    it "enabled_for? false -> does not run even with nil allowlist" do
      off = provider(id: "C", fragments: [frag("c", source: "C")], enabled: false)
      pkg = build([pa, off])
      expect(pkg.system).to eq("a")
    end
  end

  describe "grouping and canonical order" do
    it "groups by placement into the right field" do
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

    it "system in priority DESC, joined with \\n\\n" do
      p = provider(id: "P", fragments: [
                     frag("P40", priority: 40, source: "P"),
                     frag("P100", priority: 100, source: "P"),
                     frag("P80", priority: 80, source: "P")
                   ])
      expect(build([p]).system).to eq("P100\n\nP80\n\nP40")
    end

    it "priority tie: alphabetical source; deterministic on repeat" do
      p = provider(id: "P", fragments: [
                     frag("fromB", priority: 80, source: "B"),
                     frag("fromA", priority: 80, source: "A")
                   ])
      first = build([p]).system
      second = build([p]).system
      expect(first).to eq("fromA\n\nfromB")
      expect(second).to eq(first)
    end

    it "history in chronological (production) order, priority does not reorder" do
      p = provider(id: "P", fragments: [
                     frag({ n: 1 }, placement: :history, priority: 10, source: "P"),
                     frag({ n: 2 }, placement: :history, priority: 90, source: "P"),
                     frag({ n: 3 }, placement: :history, priority: 50, source: "P")
                   ])
      expect(build([p]).history).to eq([{ n: 1 }, { n: 2 }, { n: 3 }])
    end
  end

  describe "token estimation (L3)" do
    it "fills nil tokens via estimator; does not overwrite provided tokens" do
      p = provider(id: "P", fragments: [
                     frag("12345678", source: "P"),         # 8 chars -> ceil(8/4)=2
                     frag("x", source: "P", tokens: 999)
                   ])
      pkg = build([p])
      tokens = pkg.fragments.map(&:tokens)
      expect(tokens).to include(2, 999)
    end

    it "history: estimates on the message text, not on Hash#to_s" do
      body = "x" * 40
      p = provider(id: "P", fragments: [
                     frag({ role: "user", content: body }, placement: :history, source: "P")
                   ])
      pkg = build([p])
      # counts the values ("user " + body = 45 chars -> ceil(45/4)=12), NOT the
      # inspect "{:role=>\"user\", :content=>\"xxxx...\"}" (which would give ~24).
      expect(pkg.fragments.first.tokens).to eq(("user #{body}").length.ceildiv(4))
      expect(pkg.fragments.first.tokens).to be < "{role: \"user\", content: \"#{body}\"}".length.ceildiv(4)
    end
  end

  describe "budget (D8, L1)" do
    it "evicts the lowest priority first and stops exactly when it fits" do
      p = provider(id: "P", fragments: [
                     frag("lo", priority: 10, source: "LO", tokens: 40),
                     frag("mid", priority: 20, source: "MID", tokens: 40),
                     frag("hi", priority: 30, source: "HI", tokens: 40)
                   ])
      pkg = build([p], profile(budget: 100)) # used 120 -> evicts 1 (the 40-token one, priority 10)
      expect(pkg.budget[:used]).to eq(80)
      expect(pkg.budget[:evicted]).to eq(["LO"])
      expect(pkg.fragments.map(&:source)).to contain_exactly("MID", "HI")
    end

    it "priority tie: evicts the one produced earlier (stable index)" do
      p = provider(id: "P", fragments: [
                     frag("first", priority: 50, source: "FIRST", tokens: 60),
                     frag("second", priority: 50, source: "SECOND", tokens: 60)
                   ])
      pkg = build([p], profile(budget: 100)) # evicts 1 of the two equal ones -> the first
      expect(pkg.budget[:evicted]).to eq(["FIRST"])
    end

    it "pinned is uncuttable (survives even with low priority)" do
      p = provider(id: "P", fragments: [
                     frag("id", priority: 1, source: "PIN", tokens: 40, pinned: true),
                     frag("big", priority: 99, source: "BIG", tokens: 40)
                   ])
      pkg = build([p], profile(budget: 50)) # evicts the non-pinned one (BIG), pinned stays
      expect(pkg.fragments.map(&:source)).to eq(["PIN"])
      expect(pkg.budget[:evicted]).to eq(["BIG"])
    end

    it "only pinned exceeding the cap -> ContextError" do
      p = provider(id: "P", fragments: [frag("id", source: "PIN", tokens: 40, pinned: true)])
      expect { build([p], profile(budget: 30)) }.to raise_error(Insika::ContextError, /unsolvable/)
    end

    it "eviction emits 1 aggregated :provider_warning" do
      p = provider(id: "P", fragments: [
                     frag("lo", priority: 10, source: "LO", tokens: 80),
                     frag("hi", priority: 90, source: "HI", tokens: 40)
                   ])
      build([p], profile(budget: 100))
      warnings = event_stream.events.select { |e| e.type == :provider_warning }
      expect(warnings.size).to eq(1)
      expect(warnings.first.data[:provider]).to eq("ContextBuilder")
    end

    it "used == cap does not trigger eviction" do
      p = provider(id: "P", fragments: [frag("x", source: "P", tokens: 100)])
      pkg = build([p], profile(budget: 100))
      expect(pkg.budget[:evicted]).to eq([])
      expect(event_stream.events).to be_empty
    end
  end

  describe "concurrent fan-out (not sequential)" do
    it "providers run in parallel: one waits for a signal the other emits" do
      cond = Async::Condition.new
      waiter = Class.new(Insika::ContextProvider) do
        define_method(:id) { "WAIT" }
        define_method(:call) do |_r|
          cond.wait # blocks until SIGNAL; if it were sequential, it would hit the timeout
          [Insika::ContextFragment.build(content: "waited", placement: :system, source: "WAIT")]
        end
      end.new
      signaler = Class.new(Insika::ContextProvider) do
        define_method(:id) { "SIGNAL" }
        define_method(:call) do |_r|
          cond.signal
          [Insika::ContextFragment.build(content: "signaled", placement: :system, source: "SIGNAL")]
        end
      end.new

      # default provider_timeout (5s): if they ran serially, WAIT would block
      # alone and would only exit by timeout (degrading) — WAIT would not appear.
      pkg = build([waiter, signaler])

      expect(pkg.fragments.map(&:source)).to contain_exactly("WAIT", "SIGNAL")
    end
  end

  describe "integration of the :prompt pair (task 16)" do
    it "before_prompt rewrites the request: providers receive the altered one" do
      # provider that echoes the request message into a fragment
      echo = Class.new(Insika::ContextProvider) do
        define_method(:id) { "ECHO" }
        define_method(:call) do |req|
          [Insika::ContextFragment.build(content: req.message, placement: :system, source: "ECHO")]
        end
      end.new
      hooks = Insika::Hooks.new
      hooks.register(:prompt, before: ->(req) { req.with(message: "REESCRITO") })

      pkg = build([echo], profile, hooks: hooks)

      expect(pkg.system).to eq("REESCRITO")
    end

    it "after_prompt rewrites the assembled ContextPackage" do
      p = provider(id: "P", fragments: [frag("orig", source: "P")])
      hooks = Insika::Hooks.new
      hooks.register(:prompt, after: ->(pkg) { pkg.with(system: "SUBSTITUÍDO") })

      pkg = build([p], profile, hooks: hooks)

      expect(pkg.system).to eq("SUBSTITUÍDO")
    end

    it "without hooks: output identical to the Builder without the :prompt pair" do
      p = provider(id: "P", fragments: [frag("x", source: "P")])
      expect(build([p]).system).to eq("x") # empty Hooks.new = no-op
    end

    it "after that raises: providers ran once, exception propagates, no re-execution" do
      calls = 0
      counting = Class.new(Insika::ContextProvider) do
        define_method(:id) { "C" }
        define_method(:call) { |_req| calls += 1; [] }
      end.new
      hooks = Insika::Hooks.new
      hooks.register(:prompt, after: ->(_pkg) { raise "after caiu" })

      expect { build([counting], profile, hooks: hooks) }.to raise_error("after caiu")
      expect(calls).to eq(1)
    end
  end

  describe "provider errors and degradation (doc 04 §6)" do
    it "optional one that fails -> :provider_warning + rest assembled" do
      bad = provider(id: "BAD", raises: RuntimeError.new("caiu"))
      good = provider(id: "GOOD", fragments: [frag("ok", source: "GOOD")])
      pkg = build([bad, good])
      expect(pkg.system).to eq("ok")
      w = event_stream.events.find { |e| e.type == :provider_warning }
      expect(w.data).to include(provider: "BAD", message: "caiu")
    end

    it "optional one that sleeps past the timeout -> warning, turn continues" do
      slow = provider(id: "SLOW", sleep_for: 0.2)
      good = provider(id: "GOOD", fragments: [frag("ok", source: "GOOD")])
      pkg = build([slow, good], profile(provider_timeout: 0.05))
      expect(pkg.system).to eq("ok")
      expect(event_stream.events.map { |e| e.data[:provider] }).to include("SLOW")
    end

    it "required one that fails -> ContextError with provider" do
      req = provider(id: "REQ", required: true, raises: RuntimeError.new("boom"))
      expect { build([req]) }.to raise_error(Insika::ContextError) { |e| expect(e.provider).to eq("REQ") }
    end

    it "slow required one -> ContextError" do
      req = provider(id: "REQ", required: true, sleep_for: 0.2)
      expect { build([req], profile(provider_timeout: 0.05)) }.to raise_error(Insika::ContextError)
    end

    it "provider that returns nil is treated as []" do
      nily = provider(id: "NIL", fragments: nil)
      good = provider(id: "GOOD", fragments: [frag("ok", source: "GOOD")])
      expect(build([nily, good]).system).to eq("ok")
    end
  end
end

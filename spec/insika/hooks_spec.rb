# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Hooks do
  subject(:hooks) { described_class.new }

  it "exposes the valid pairs frozen" do
    expect(described_class::PAIRS).to eq(%i[task prompt agent tool])
    expect(described_class::PAIRS).to be_frozen
  end

  it "befores run in registration order, chaining the subject" do
    hooks.register(:prompt, before: ->(s) { "#{s}-1" })
    hooks.register(:prompt, before: ->(s) { "#{s}-2" })

    seen = nil
    hooks.around(:prompt, "x") { |s| seen = s }

    expect(seen).to eq("x-1-2")
  end

  it "afters run in REVERSE registration order" do
    order = []
    hooks.register(:prompt, after: ->(r) { order << :a; r })
    hooks.register(:prompt, after: ->(r) { order << :b; r })

    hooks.around(:prompt, "x") { |s| s }

    expect(order).to eq(%i[b a]) # last registered runs first
  end

  it "before can change the subject the block receives" do
    hooks.register(:prompt, before: ->(_s) { "novo" })
    seen = nil
    hooks.around(:prompt, "original") { |s| seen = s }
    expect(seen).to eq("novo")
  end

  it "after can change the result returned by around" do
    hooks.register(:prompt, after: ->(r) { "#{r}-transformado" })
    result = hooks.around(:prompt, "x") { |_s| "resultado" }
    expect(result).to eq("resultado-transformado")
  end

  it "no registrations: pure passthrough (block receives the original subject)" do
    seen = nil
    result = hooks.around(:agent, "subj") { |s| seen = s; "res" }
    expect([seen, result]).to eq(%w[subj res])
  end

  it "after does NOT re-run the stage; exception from after propagates after 1 execution" do
    count = 0
    hooks.register(:prompt, after: ->(_r) { raise "after caiu" })

    expect { hooks.around(:prompt, "x") { |_s| count += 1 } }.to raise_error("after caiu")
    expect(count).to eq(1)
  end

  it "before that raises: stage never runs; exception propagates" do
    count = 0
    hooks.register(:prompt, before: ->(_s) { raise "before caiu" })

    expect { hooks.around(:prompt, "x") { |_s| count += 1 } }.to raise_error("before caiu")
    expect(count).to eq(0)
  end

  it "unknown pair -> ArgumentError in register and around" do
    expect { hooks.register(:foo, before: ->(s) { s }) }.to raise_error(ArgumentError)
    expect { hooks.around(:foo, "x") { |s| s } }.to raise_error(ArgumentError)
  end

  it "register with neither before nor after is a valid no-op" do
    expect { hooks.register(:prompt) }.not_to raise_error
    seen = nil
    hooks.around(:prompt, "x") { |s| seen = s }
    expect(seen).to eq("x")
  end

  it "multiple befores on the same pair: all run chained" do
    3.times { |i| hooks.register(:tool, before: ->(s) { s + i.to_s }) }
    seen = nil
    hooks.around(:tool, "") { |s| seen = s }
    expect(seen).to eq("012")
  end

  describe "run_before / run_after halves" do
    it "run_before chains in registration order" do
      hooks.register(:tool, before: ->(s) { "#{s}-1" })
      hooks.register(:tool, before: ->(s) { "#{s}-2" })
      expect(hooks.run_before(:tool, "x")).to eq("x-1-2")
    end

    it "run_after applies in REVERSE registration order" do
      order = []
      hooks.register(:tool, after: ->(r) { order << :a; r })
      hooks.register(:tool, after: ->(r) { order << :b; r })
      hooks.run_after(:tool, "x")
      expect(order).to eq(%i[b a])
    end

    it "around ≡ run_after(yield(run_before))" do
      hooks.register(:tool, before: ->(s) { "#{s}>b" })
      hooks.register(:tool, after: ->(r) { "#{r}>a" })
      via_around = hooks.around(:tool, "x") { |s| "#{s}|body" }
      manual = hooks.run_after(:tool, "#{hooks.run_before(:tool, 'x')}|body")
      expect(via_around).to eq(manual)
    end

    it "pair with no hooks: halves return the argument intact" do
      expect(hooks.run_before(:agent, "x")).to eq("x")
      expect(hooks.run_after(:agent, "y")).to eq("y")
    end

    it "unknown pair -> ArgumentError in the halves" do
      expect { hooks.run_before(:foo, "x") }.to raise_error(ArgumentError)
      expect { hooks.run_after(:foo, "x") }.to raise_error(ArgumentError)
    end
  end
end

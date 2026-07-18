# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::MiddlewareStack do
  # Minimal TurnState (double): only the fields the links touch.
  def state = Struct.new(:message, :halt_reason).new

  # Link that logs entry/exit into a shared array.
  def logging_mw(log, tag)
    Class.new(Harness::Middleware) do
      define_method(:call) do |st, &nxt|
        log << "#{tag}:in"
        result = nxt.call(st)
        log << "#{tag}:out"
        result
      end
    end.new
  end

  it "runs in registration order (outer->inner) and returns in reverse order" do
    log = []
    stack = described_class.new([logging_mw(log, "A"), logging_mw(log, "B")])

    stack.call(state) { |_s| log << "terminal" }

    expect(log).to eq(%w[A:in B:in terminal B:out A:out])
  end

  it "base Middleware is pass-through (terminal runs, state unchanged)" do
    stack = described_class.new([Harness::Middleware.new])
    ran = false
    st = state
    stack.call(st) { |_s| ran = true }
    expect(ran).to be(true)
  end

  it "short-circuit: link does not call nxt -> terminal and subsequent links do not run" do
    log = []
    halting = Class.new(Harness::Middleware) do
      define_method(:call) { |st, &_nxt| st.halt_reason = "rate limit" }
    end.new
    stack = described_class.new([halting, logging_mw(log, "B")])

    terminal_ran = false
    st = state
    stack.call(st) { |_s| terminal_ran = true }

    expect(terminal_ran).to be(false)
    expect(log).to be_empty # B (after the halting) never ran
    expect(st.halt_reason).to eq("rate limit")
  end

  it "state modification is visible to the next link and the terminal" do
    writer = Class.new(Harness::Middleware) do
      define_method(:call) { |st, &nxt| st.message = "x"; nxt.call(st) }
    end.new
    stack = described_class.new([writer])

    seen = nil
    stack.call(state) { |s| seen = s.message }
    expect(seen).to eq("x")
  end

  it "empty stack -> terminal runs with the same state" do
    st = state
    seen = nil
    described_class.new([]).call(st) { |s| seen = s }
    expect(seen).to be(st)
  end

  it "exception in a link propagates (stack does not rescue)" do
    boom = Class.new(Harness::Middleware) do
      def call(_st, &_nxt) = raise "middleware caiu"
    end.new
    expect { described_class.new([boom]).call(state) { |_s| :ok } }.to raise_error("middleware caiu")
  end

  it "returns the terminal's value" do
    expect(described_class.new([Harness::Middleware.new]).call(state) { |_s| :resultado }).to eq(:resultado)
  end
end

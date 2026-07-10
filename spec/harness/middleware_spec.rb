# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::MiddlewareStack do
  # TurnState mínimo (duplo): só os campos que os elos tocam.
  def state = Struct.new(:message, :halt_reason).new

  # Elo que loga entrada/saída num array compartilhado.
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

  it "executa na ordem de registro (externo->interno) e volta em ordem inversa" do
    log = []
    stack = described_class.new([logging_mw(log, "A"), logging_mw(log, "B")])

    stack.call(state) { |_s| log << "terminal" }

    expect(log).to eq(%w[A:in B:in terminal B:out A:out])
  end

  it "Middleware base é pass-through (terminal roda, state inalterado)" do
    stack = described_class.new([Harness::Middleware.new])
    ran = false
    st = state
    stack.call(st) { |_s| ran = true }
    expect(ran).to be(true)
  end

  it "curto-circuito: elo não chama nxt -> terminal e elos seguintes não rodam" do
    log = []
    halting = Class.new(Harness::Middleware) do
      define_method(:call) { |st, &_nxt| st.halt_reason = "rate limit" }
    end.new
    stack = described_class.new([halting, logging_mw(log, "B")])

    terminal_ran = false
    st = state
    stack.call(st) { |_s| terminal_ran = true }

    expect(terminal_ran).to be(false)
    expect(log).to be_empty # B (após o halting) nunca rodou
    expect(st.halt_reason).to eq("rate limit")
  end

  it "modificação do state é visível ao próximo elo e ao terminal" do
    writer = Class.new(Harness::Middleware) do
      define_method(:call) { |st, &nxt| st.message = "x"; nxt.call(st) }
    end.new
    stack = described_class.new([writer])

    seen = nil
    stack.call(state) { |s| seen = s.message }
    expect(seen).to eq("x")
  end

  it "stack vazia -> terminal executa com o mesmo state" do
    st = state
    seen = nil
    described_class.new([]).call(st) { |s| seen = s }
    expect(seen).to be(st)
  end

  it "exceção em elo propaga (stack não faz rescue)" do
    boom = Class.new(Harness::Middleware) do
      def call(_st, &_nxt) = raise "middleware caiu"
    end.new
    expect { described_class.new([boom]).call(state) { |_s| :ok } }.to raise_error("middleware caiu")
  end

  it "devolve o valor do terminal" do
    expect(described_class.new([Harness::Middleware.new]).call(state) { |_s| :resultado }).to eq(:resultado)
  end
end

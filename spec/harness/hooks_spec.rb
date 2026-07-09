# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Hooks do
  subject(:hooks) { described_class.new }

  it "expõe os pares válidos congelados" do
    expect(described_class::PAIRS).to eq(%i[task prompt agent tool])
    expect(described_class::PAIRS).to be_frozen
  end

  it "befores rodam na ordem de registro, encadeando o subject" do
    hooks.register(:prompt, before: ->(s) { "#{s}-1" })
    hooks.register(:prompt, before: ->(s) { "#{s}-2" })

    seen = nil
    hooks.around(:prompt, "x") { |s| seen = s }

    expect(seen).to eq("x-1-2")
  end

  it "afters rodam na ordem INVERSA de registro" do
    order = []
    hooks.register(:prompt, after: ->(r) { order << :a; r })
    hooks.register(:prompt, after: ->(r) { order << :b; r })

    hooks.around(:prompt, "x") { |s| s }

    expect(order).to eq(%i[b a]) # último registrado roda primeiro
  end

  it "before pode alterar o subject que o bloco recebe" do
    hooks.register(:prompt, before: ->(_s) { "novo" })
    seen = nil
    hooks.around(:prompt, "original") { |s| seen = s }
    expect(seen).to eq("novo")
  end

  it "after pode alterar o resultado retornado por around" do
    hooks.register(:prompt, after: ->(r) { "#{r}-transformado" })
    result = hooks.around(:prompt, "x") { |_s| "resultado" }
    expect(result).to eq("resultado-transformado")
  end

  it "sem registros: passthrough puro (bloco recebe o subject original)" do
    seen = nil
    result = hooks.around(:agent, "subj") { |s| seen = s; "res" }
    expect([seen, result]).to eq(%w[subj res])
  end

  it "after NÃO reexecuta o estágio; exceção do after propaga após 1 execução" do
    count = 0
    hooks.register(:prompt, after: ->(_r) { raise "after caiu" })

    expect { hooks.around(:prompt, "x") { |_s| count += 1 } }.to raise_error("after caiu")
    expect(count).to eq(1)
  end

  it "before que levanta: estágio nunca roda; exceção propaga" do
    count = 0
    hooks.register(:prompt, before: ->(_s) { raise "before caiu" })

    expect { hooks.around(:prompt, "x") { |_s| count += 1 } }.to raise_error("before caiu")
    expect(count).to eq(0)
  end

  it "par desconhecido -> ArgumentError em register e around" do
    expect { hooks.register(:foo, before: ->(s) { s }) }.to raise_error(ArgumentError)
    expect { hooks.around(:foo, "x") { |s| s } }.to raise_error(ArgumentError)
  end

  it "register sem before nem after é no-op válido" do
    expect { hooks.register(:prompt) }.not_to raise_error
    seen = nil
    hooks.around(:prompt, "x") { |s| seen = s }
    expect(seen).to eq("x")
  end

  it "múltiplos befores no mesmo par: todos rodam encadeados" do
    3.times { |i| hooks.register(:tool, before: ->(s) { s + i.to_s }) }
    seen = nil
    hooks.around(:tool, "") { |s| seen = s }
    expect(seen).to eq("012")
  end
end

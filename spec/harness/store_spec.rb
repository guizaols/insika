# frozen_string_literal: true

# Carrega a suíte de contrato para garantir que o arquivo parseia limpo
# (a primeira execução real contra um backend é a task 3).
require_relative "store_contract"

RSpec.describe Harness::Store do
  # Backend incompleto: só inclui o módulo, não sobrescreve nada.
  subject(:incomplete) { Class.new { include Harness::Store }.new }

  it "levanta NotImplementedError em #get" do
    expect { incomplete.get("s", "k") }.to raise_error(NotImplementedError)
  end

  it "levanta NotImplementedError em #set" do
    expect { incomplete.set("s", "k", 1) }.to raise_error(NotImplementedError)
  end

  it "levanta NotImplementedError em #delete" do
    expect { incomplete.delete("s", "k") }.to raise_error(NotImplementedError)
  end

  it "levanta NotImplementedError em #list" do
    expect { incomplete.list("s") }.to raise_error(NotImplementedError)
  end

  it "levanta NotImplementedError em #transaction" do
    expect { incomplete.transaction { 1 } }.to raise_error(NotImplementedError)
  end
end

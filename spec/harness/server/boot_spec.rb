# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/boot"

# doc 07 §7: ordem plugins→stores→recovery→(app). App só é retornado DEPOIS do
# recovery. Store corrompido no boot -> aborta (não retorna app).
RSpec.describe Harness::Server::Boot do
  # Wiring duplo: registra a ordem das chamadas num array compartilhado.
  class WiringDouble
    attr_reader :calls

    def initialize(calls, recovery:, app: :the_app)
      @calls = calls
      @recovery = recovery
      @app = app
    end

    def load_plugins = @calls << :plugins
    def build_stores = @calls << :stores
    def recovery = @recovery
    def app
      @calls << :app
      @app
    end
  end

  RecoveryDouble = Struct.new(:calls, :result, :error) do
    def run
      calls << :recovery
      raise error if error

      result || { resumed: [], failed: [] }
    end
  end

  it "executa plugins -> stores -> recovery e só então devolve o app" do
    calls = []
    wiring = WiringDouble.new(calls, recovery: RecoveryDouble.new(calls, { resumed: [], failed: [] }, nil))

    app = described_class.new(wiring, logger: nil).call

    expect(calls).to eq(%i[plugins stores recovery app])
    expect(app).to eq(:the_app)
  end

  it "recovery levanta StoreError -> Boot aborta e NÃO retorna o app" do
    calls = []
    boom = RecoveryDouble.new(calls, nil, Harness::StoreError.new("db corrompido"))
    wiring = WiringDouble.new(calls, recovery: boom)

    expect { described_class.new(wiring, logger: nil).call }.to raise_error(Harness::StoreError)
    expect(calls).not_to include(:app) # abortou antes de liberar o app p/ o listen
  end

  it "task irrecuperável (failed) não derruba o boot" do
    calls = []
    wiring = WiringDouble.new(calls, recovery: RecoveryDouble.new(calls, { resumed: [], failed: ["t-1"] }, nil))

    app = described_class.new(wiring, logger: nil).call

    expect(app).to eq(:the_app)
    expect(calls).to eq(%i[plugins stores recovery app])
  end

  it "envolve o recovery em Sync quando não há reactor corrente" do
    calls = []
    recovery = RecoveryDouble.new(calls, { resumed: [], failed: [] }, nil)
    wiring = WiringDouble.new(calls, recovery: recovery)

    # Fora de qualquer Async: não deve levantar (o Boot cria o reactor).
    expect { described_class.new(wiring, logger: nil).call }.not_to raise_error
    expect(calls).to include(:recovery)
  end
end

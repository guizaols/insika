# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::CommandBus do
  subject(:bus) { described_class.new(event_stream: event_stream) }

  let(:event_stream) { double("event_stream") }

  it "roteia dispatch para o handler registrado e retorna seu resultado" do
    bus.register(:echo, ->(command) { [:handled, command.type] })

    result = bus.dispatch(Harness::Command.build(:echo, {}))

    expect(result).to eq([:handled, :echo])
  end

  it "chama o handler com o próprio Command" do
    received = nil
    bus.register(:capture, ->(command) { received = command })
    command = Harness::Command.build(:capture, { a: 1 })

    bus.dispatch(command)

    expect(received).to be(command)
  end

  it "levanta ValidationError com o tipo na mensagem para tipo desconhecido" do
    expect { bus.dispatch(Harness::Command.build(:nope, {})) }
      .to raise_error(Harness::ValidationError, /nope/)
  end

  it "re-registro do mesmo tipo: último handler vence" do
    bus.register(:x, ->(_) { :primeiro })
    bus.register(:x, ->(_) { :segundo })

    expect(bus.dispatch(Harness::Command.build(:x, {}))).to eq(:segundo)
  end
end

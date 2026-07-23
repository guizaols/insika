# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::CommandBus do
  subject(:bus) { described_class.new }

  it "routes dispatch to the registered handler and returns its result" do
    bus.register(:echo, ->(command) { [:handled, command.type] })

    result = bus.dispatch(Insika::Command.build(:echo, {}))

    expect(result).to eq([:handled, :echo])
  end

  it "calls the handler with the Command itself" do
    received = nil
    bus.register(:capture, ->(command) { received = command })
    command = Insika::Command.build(:capture, { a: 1 })

    bus.dispatch(command)

    expect(received).to be(command)
  end

  it "raises ValidationError with the type in the message for an unknown type" do
    expect { bus.dispatch(Insika::Command.build(:nope, {})) }
      .to raise_error(Insika::ValidationError, /nope/)
  end

  it "re-registering the same type: last handler wins" do
    bus.register(:x, ->(_) { :primeiro })
    bus.register(:x, ->(_) { :segundo })

    expect(bus.dispatch(Insika::Command.build(:x, {}))).to eq(:segundo)
  end
end

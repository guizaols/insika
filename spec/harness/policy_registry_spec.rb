# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::PolicyRegistry do
  subject(:registry) { described_class.new }

  # Policy fake (PORO com #decide).
  let(:policy_class) do
    Class.new(Harness::Policy::Base) do
      def decide(_request) = :decided
    end
  end

  it "resolve instancia a policy registrada" do
    registry.register("p", policy_class)
    expect(registry.resolve("p")).to be_a(policy_class)
  end

  it "fetch é alias de resolve (duck-type do Policy::Engine)" do
    registry.register("p", policy_class)
    expect(registry.fetch("p")).to be_a(policy_class)
  end

  it "resolve/fetch de nome inexistente -> NotFoundError" do
    expect { registry.resolve("nope") }.to raise_error(Harness::NotFoundError)
    expect { registry.fetch("nope") }.to raise_error(Harness::NotFoundError)
  end
end

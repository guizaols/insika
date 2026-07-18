# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::PolicyRegistry do
  subject(:registry) { described_class.new }

  # Fake policy (PORO with #decide).
  let(:policy_class) do
    Class.new(Harness::Policy::Base) do
      def decide(_request) = :decided
    end
  end

  it "resolve instantiates the registered policy" do
    registry.register("p", policy_class)
    expect(registry.resolve("p")).to be_a(policy_class)
  end

  it "fetch is an alias of resolve (duck-type of Policy::Engine)" do
    registry.register("p", policy_class)
    expect(registry.fetch("p")).to be_a(policy_class)
  end

  it "resolve/fetch of nonexistent name -> NotFoundError" do
    expect { registry.resolve("nope") }.to raise_error(Harness::NotFoundError)
    expect { registry.fetch("nope") }.to raise_error(Harness::NotFoundError)
  end
end

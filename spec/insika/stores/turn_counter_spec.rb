# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Stores::TurnCounter do
  let(:backend) { described_class.attach(Insika::Stores::Memory.new) }
  let(:timing) { Insika::TurnTiming.new }

  around do |ex|
    Fiber[Insika::TurnTiming::FIBER_KEY] = nil
    ex.run
  ensure
    Fiber[Insika::TurnTiming::FIBER_KEY] = nil
  end

  it "counts each call into the current turn's timing" do
    Fiber[Insika::TurnTiming::FIBER_KEY] = timing
    backend.set("sessions", "s1", { "a" => 1 })
    backend.get("sessions", "s1")
    backend.get("config:agents", "bia")

    expect(timing.to_h[:store_calls_by]).to eq("get config:agents" => 1, "get sessions" => 1, "set sessions" => 1)
  end

  it "counts calls made from child fibers" do
    Sync do
      Fiber[Insika::TurnTiming::FIBER_KEY] = timing
      2.times.map { Async { backend.get("sessions", "s1") } }.each(&:wait)
    end

    expect(timing.to_h[:store_calls]).to eq(2)
  end

  it "counts nothing when no turn is running" do
    expect { backend.get("sessions", "s1") }.not_to raise_error
    expect(timing.to_h).not_to have_key(:store_calls)
  end

  it "keeps the backend's class and behaviour" do
    expect(backend).to be_a(Insika::Stores::Memory)
    backend.set("x", "k", { "v" => 2 })
    expect(backend.get("x", "k")).to eq("v" => 2)
  end

  it "attaching twice counts once" do
    described_class.attach(backend)
    Fiber[Insika::TurnTiming::FIBER_KEY] = timing
    backend.get("x", "k")
    expect(timing.to_h[:store_calls]).to eq(1)
  end
end

# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Commands::SeedDemoData do
  subject(:handler) { described_class.new(seeder: seeder, event_stream: stream) }

  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  # The Seeder itself is covered by its own spec; this one is about the
  # thin bus adapter — the force flag and the event, not the seeding logic.
  let(:seeder) { instance_double(Insika::Demo::Seeder) }

  def cmd(payload) = Insika::Command.build(:seed_demo_data, payload)

  it "forwards force: false by default" do
    allow(seeder).to receive(:seed!).with(force: false).and_return(seeded: false, reason: "already_seeded")

    handler.call(cmd({}))

    expect(seeder).to have_received(:seed!).with(force: false)
  end

  it "coerces a truthy force (string, as the Studio checkbox sends it)" do
    allow(seeder).to receive(:seed!).with(force: true).and_return(seeded: true, agent: "demo-store", counts: {})

    handler.call(cmd({ "force" => "1" }))

    expect(seeder).to have_received(:seed!).with(force: true)
  end

  it "emits :demo_data_seeded with the counts when it actually seeded" do
    allow(seeder).to receive(:seed!).and_return(seeded: true, agent: "demo-store", counts: { followups: 5 })

    result = handler.call(cmd({}))

    expect(result).to eq(seeded: true, agent: "demo-store", counts: { followups: 5 })
    expect(events.map(&:type)).to eq([:demo_data_seeded])
    expect(events.first.data).to eq(agent: "demo-store", counts: { followups: 5 })
  end

  it "emits nothing on a no-op" do
    allow(seeder).to receive(:seed!).and_return(seeded: false, reason: "already_seeded")

    handler.call(cmd({}))

    expect(events).to be_empty
  end
end

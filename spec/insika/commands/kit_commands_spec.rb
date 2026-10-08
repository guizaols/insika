# frozen_string_literal: true

require "spec_helper"

RSpec.describe "kit commands" do
  let(:settings) { Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }
  let(:write) { Insika::Commands::WriteKit.new(settings_store: settings, event_stream: event_stream) }
  let(:delete) { Insika::Commands::DeleteKit.new(settings_store: settings, event_stream: event_stream) }

  def cmd(type, payload) = Insika::Command.build(type, payload, transport: :test)

  it "writes a kit and emits kit_written" do
    kit = write.call(cmd(:write_kit, { "name" => "grocery", "tools" => ["add_to_cart"] }))
    expect(kit["tools"]).to eq(%w[add_to_cart])
    expect(settings.kits.keys).to eq(%w[grocery])
    expect(events.map(&:type)).to eq([:kit_written])
  end

  it "rejects a bad name" do
    expect { write.call(cmd(:write_kit, { "name" => "Bad" })) }.to raise_error(Insika::ValidationError)
  end

  it "deletes, and 404s an unknown kit" do
    write.call(cmd(:write_kit, { "name" => "grocery" }))
    expect(delete.call(cmd(:delete_kit, { "name" => "grocery" }))).to eq(name: "grocery", deleted: true)
    expect { delete.call(cmd(:delete_kit, { "name" => "grocery" })) }.to raise_error(Insika::NotFoundError)
  end
end

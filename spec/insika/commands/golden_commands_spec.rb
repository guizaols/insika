# frozen_string_literal: true

require "spec_helper"

# an eval case becomes authorable at runtime, through
# the bus like every other write. The rubric is plain language, which is exactly why a
# domain owner has to be able to write one without a checkout.
RSpec.describe "Golden commands" do
  let(:store) { Insika::GoldenStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Insika::Command.build(type, payload)

  def a_case(id: "loja-cupom")
    { "id" => id, "agent" => "loja", "turns" => [{ "user" => "tem cupom?" }],
      "expect" => { "rubric" => "Consults the coupon by tool." } }
  end

  describe Insika::Commands::WriteGolden do
    subject(:handler) { described_class.new(golden_store: store, event_stream: stream) }

    it "stores the case, emits :golden_written, answers with id + agent" do
      result = handler.call(cmd(:write_golden, { "case" => a_case }))

      expect(result).to eq(id: "loja-cupom", agent: "loja")
      expect(store.find("loja-cupom").rubric).to eq("Consults the coupon by tool.")
      expect(events.map(&:type)).to eq([:golden_written])
      expect(events.first.data).to eq(id: "loja-cupom", agent: "loja")
    end

    it "requires a case, and rejects a malformed one through the one loader" do
      expect { handler.call(cmd(:write_golden, {})) }
        .to raise_error(Insika::ValidationError, /case is required/)
      expect { handler.call(cmd(:write_golden, { "case" => a_case.merge("agent" => " ") })) }
        .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /'agent' is required/)
      expect(events).to be_empty # nothing emitted for a write that did not happen
    end
  end

  describe Insika::Commands::DeleteGolden do
    subject(:handler) { described_class.new(golden_store: store, event_stream: stream) }

    it "removes the case and reports whether it existed" do
      store.write(a_case)

      expect(handler.call(cmd(:delete_golden, { "id" => "loja-cupom" }))).to eq(id: "loja-cupom", existed: true)
      expect(handler.call(cmd(:delete_golden, { "id" => "loja-cupom" }))).to eq(id: "loja-cupom", existed: false)
      expect(events.map(&:type)).to eq(%i[golden_deleted golden_deleted])
    end

    it "requires an id" do
      expect { handler.call(cmd(:delete_golden, {})) }.to raise_error(Insika::ValidationError, /id is required/)
    end
  end
end

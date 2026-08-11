# frozen_string_literal: true

require "spec_helper"

# durable general settings + masking sentinel.
RSpec.describe "Settings + masking" do
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  describe Insika::SecretMasking do
    it "mask: present -> sentinel; absent -> nil" do
      expect(described_class.mask("sk-123")).to eq("__OCULTO__")
      expect(described_class.mask(nil)).to be_nil
      expect(described_class.mask("")).to be_nil
    end

    it "reconcile: sentinel/nil preserve; new string replaces; '' clears" do
      expect(described_class.reconcile("__OCULTO__", "old")).to eq("old")
      expect(described_class.reconcile(nil, "old")).to eq("old")
      expect(described_class.reconcile("new", "old")).to eq("new")
      expect(described_class.reconcile("", "old")).to be_nil
    end
  end

  describe Insika::SettingsStore do
    subject(:settings) { described_class.new(config_store: config_store) }

    it "get returns the defaults when the store is empty" do
      expect(settings.get["streaming"]).to be(true)
      expect(settings.get["request_timeout"]).to eq(120)
      expect(settings.get["compaction"]["keep_last"]).to eq(20)
    end

    it "edge limits default OFF with the windows pre-filled" do
      edge = settings.get["edge"]
      expect(edge["chat_rate_limit"]).to be_nil
      expect(edge["agent_token_ceiling"]).to be_nil
      expect(edge["chat_rate_window"]).to eq(60)
      expect(edge["agent_token_window"]).to eq(86_400)
    end

    it "an edge patch deep-merges (a limit save keeps the window defaults)" do
      settings.update("edge" => { "chat_rate_limit" => 20 })
      edge = settings.get["edge"]
      expect(edge["chat_rate_limit"]).to eq(20)
      expect(edge["chat_rate_window"]).to eq(60)
    end

    it "update does a shallow merge and deep in compaction; persists" do
      settings.update("streaming" => false, "compaction" => { "enabled" => true })
      got = settings.get
      expect(got["streaming"]).to be(false)
      expect(got["compaction"]["enabled"]).to be(true)
      expect(got["compaction"]["keep_last"]).to eq(20) # preserved from default
      expect(got["request_timeout"]).to eq(120)        # untouched
    end
  end

  describe Insika::Commands::UpdateSettings do
    subject(:handler) { described_class.new(settings_store: Insika::SettingsStore.new(config_store: config_store), event_stream: stream) }

    def cmd(payload) = Insika::Command.build(:update_settings, payload)

    it "applies the patch and emits :settings_updated" do
      result = handler.call(cmd("patch" => { "turn_timeout" => 300 }))
      expect(result["turn_timeout"]).to eq(300)
      expect(events.map(&:type)).to eq([:settings_updated])
    end

    it "patch absent/empty -> ValidationError" do
      expect { handler.call(cmd({})) }.to raise_error(Insika::ValidationError, /patch/)
      expect { handler.call(cmd("patch" => {})) }.to raise_error(Insika::ValidationError, /empty/)
    end
  end
end

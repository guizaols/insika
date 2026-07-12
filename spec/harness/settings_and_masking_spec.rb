# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa D (task 10 / D6): settings gerais duráveis + masking sentinel.
RSpec.describe "Settings + masking (Fase 4 Etapa D)" do
  let(:config_store) { Harness::ConfigStore.new(store: Harness::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  describe Harness::SecretMasking do
    it "mask: presente -> sentinel; ausente -> nil" do
      expect(described_class.mask("sk-123")).to eq("__OCULTO__")
      expect(described_class.mask(nil)).to be_nil
      expect(described_class.mask("")).to be_nil
    end

    it "reconcile: sentinel/nil preservam; string nova substitui; '' limpa" do
      expect(described_class.reconcile("__OCULTO__", "old")).to eq("old")
      expect(described_class.reconcile(nil, "old")).to eq("old")
      expect(described_class.reconcile("new", "old")).to eq("new")
      expect(described_class.reconcile("", "old")).to be_nil
    end
  end

  describe Harness::SettingsStore do
    subject(:settings) { described_class.new(config_store: config_store) }

    it "get devolve os defaults quando o store está vazio" do
      expect(settings.get["streaming"]).to be(true)
      expect(settings.get["request_timeout"]).to eq(120)
      expect(settings.get["compaction"]["keep_last"]).to eq(20)
    end

    it "update faz merge raso e deep em compaction; persiste" do
      settings.update("streaming" => false, "compaction" => { "enabled" => true })
      got = settings.get
      expect(got["streaming"]).to be(false)
      expect(got["compaction"]["enabled"]).to be(true)
      expect(got["compaction"]["keep_last"]).to eq(20) # preservado do default
      expect(got["request_timeout"]).to eq(120)        # intocado
    end
  end

  describe Harness::Commands::UpdateSettings do
    subject(:handler) { described_class.new(settings_store: Harness::SettingsStore.new(config_store: config_store), event_stream: stream) }

    def cmd(payload) = Harness::Command.build(:update_settings, payload)

    it "aplica o patch e emite :settings_updated" do
      result = handler.call(cmd("patch" => { "turn_timeout" => 300 }))
      expect(result["turn_timeout"]).to eq(300)
      expect(events.map(&:type)).to eq([:settings_updated])
    end

    it "patch ausente/vazio -> ValidationError" do
      expect { handler.call(cmd({})) }.to raise_error(Harness::ValidationError, /patch/)
      expect { handler.call(cmd("patch" => {})) }.to raise_error(Harness::ValidationError, /vazio/)
    end
  end
end

# frozen_string_literal: true

require "spec_helper"

# authorable LLM providers + runtime reconfigure
# + key masking. Runs WITHOUT ruby_llm/a key: the configurator receives a fake
# config target (`configure:` injection), so nothing touches the real gem.
RSpec.describe "LLM providers" do
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:store) { Insika::LLMProviderStore.new(config_store: config_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  # Config target that pretends to be RubyLLM.config: accepts <api>_api_key= and
  # <api>_api_base= via method_missing and stores them in an observable Hash.
  let(:fake_config) do
    Class.new do
      attr_reader :calls
      def initialize = (@calls = {})
      def respond_to_missing?(name, _ = false) = name.to_s.end_with?("=")
      def method_missing(name, *args)
        return super unless name.to_s.end_with?("=")

        @calls[name.to_s.chomp("=")] = args.first
      end
    end.new
  end
  let(:configurator) { Insika::LLMConfigurator.new(provider_store: store, configure: ->(&blk) { blk.call(fake_config) }) }

  describe Insika::LLMProviderStore do
    it "upsert stores and returns MASKED; get_raw returns the real key" do
      masked = store.upsert("api" => "deepseek", "base_url" => "https://api.deepseek.com/v1", "api_key" => "sk-secret", "models" => %w[deepseek-chat])
      expect(masked["api_key"]).to eq("__OCULTO__")
      expect(masked["base_url"]).to eq("https://api.deepseek.com/v1")
      expect(store.get_raw("deepseek")["api_key"]).to eq("sk-secret")
    end

    it "sentinel on rewrite preserves the key; '' clears it" do
      store.upsert("api" => "deepseek", "api_key" => "sk-secret")
      store.upsert("api" => "deepseek", "api_key" => "__OCULTO__", "base_url" => "https://x")
      expect(store.get_raw("deepseek")["api_key"]).to eq("sk-secret") # preserved
      expect(store.get_raw("deepseek")["base_url"]).to eq("https://x")
      store.upsert("api" => "deepseek", "api_key" => "")
      expect(store.get_raw("deepseek")["api_key"]).to be_nil # cleared
    end

    it "all masks every entry; api required" do
      store.upsert("api" => "openai", "api_key" => "sk-1")
      expect(store.all.map { |r| r["api_key"] }).to eq(["__OCULTO__"])
      expect { store.upsert("base_url" => "x") }.to raise_error(Insika::ValidationError, /api/)
    end
  end

  describe Insika::LLMConfigurator do
    it "applies <api>_api_key/_api_base to the config; returns applied" do
      store.upsert("api" => "deepseek", "base_url" => "https://api.deepseek.com/v1", "api_key" => "sk-secret")
      result = configurator.apply
      expect(result[:applied]).to eq(["deepseek"])
      expect(fake_config.calls["deepseek_api_key"]).to eq("sk-secret")
      expect(fake_config.calls["deepseek_api_base"]).to eq("https://api.deepseek.com/v1")
    end

    it "a provider without api_key goes into skipped (not applied)" do
      store.upsert("api" => "openai") # no key
      result = configurator.apply
      expect(result[:applied]).to be_empty
      expect(result[:skipped].first[:reason]).to match(/sem api_key/)
    end

    it "unapply zeroes the provider's key/base in the config (delete without restart)" do
      store.upsert("api" => "deepseek", "api_key" => "sk-secret", "base_url" => "https://x")
      configurator.apply
      expect(configurator.unapply("deepseek")).to eq({ unapplied: true })
      expect(fake_config.calls["deepseek_api_key"]).to be_nil
      expect(fake_config.calls["deepseek_api_base"]).to be_nil
    end

    describe "#refresh" do
      # Another worker process authored the provider: only the shared store saw it.
      let(:other_worker) { Insika::LLMProviderStore.new(config_store: config_store) }

      it "applies a provider written by another process" do
        other_worker.upsert("api" => "openrouter", "api_key" => "sk-or")
        configurator.refresh
        expect(fake_config.calls["openrouter_api_key"]).to eq("sk-or")
      end

      it "applies a changed key, and leaves the config alone while nothing changed" do
        other_worker.upsert("api" => "openrouter", "api_key" => "sk-1")
        configurator.refresh
        fake_config.calls.clear
        configurator.refresh
        expect(fake_config.calls).to be_empty

        other_worker.upsert("api" => "openrouter", "api_key" => "sk-2")
        configurator.refresh
        expect(fake_config.calls["openrouter_api_key"]).to eq("sk-2")
      end

      it "unapplies a provider deleted elsewhere, never a key it did not apply" do
        fake_config.calls["deepseek_api_key"] = "from-env"
        other_worker.upsert("api" => "openrouter", "api_key" => "sk-or")
        configurator.refresh
        other_worker.delete("openrouter")
        configurator.refresh
        expect(fake_config.calls["openrouter_api_key"]).to be_nil
        expect(fake_config.calls["deepseek_api_key"]).to eq("from-env")
      end

      it "deleting a record that carried no key leaves the environment's key alone" do
        fake_config.calls["deepseek_api_key"] = "from-env"
        other_worker.upsert("api" => "deepseek", "base_url" => "https://x") # no key: env key stays
        configurator.refresh
        other_worker.delete("deepseek")
        configurator.refresh
        expect(fake_config.calls["deepseek_api_key"]).to eq("from-env")
      end

      it "a key cleared elsewhere stops being used" do
        other_worker.upsert("api" => "openrouter", "api_key" => "sk-leaked")
        configurator.refresh
        other_worker.upsert("api" => "openrouter", "api_key" => "")
        configurator.refresh
        expect(fake_config.calls["openrouter_api_key"]).to be_nil
      end

      it "a store error keeps the current config and is retried on the next call" do
        other_worker.upsert("api" => "openrouter", "api_key" => "sk-or")
        allow(store).to receive(:all_raw).and_raise(Insika::Error, "busy")
        expect { configurator.refresh }.to output(/busy/).to_stderr
        allow(store).to receive(:all_raw).and_call_original
        configurator.refresh
        expect(fake_config.calls["openrouter_api_key"]).to eq("sk-or")
      end
    end
  end

  describe Insika::Commands::UpsertLLMProvider do
    subject(:handler) { described_class.new(provider_store: store, configurator: configurator, event_stream: stream) }

    def cmd(payload) = Insika::Command.build(:upsert_llm_provider, payload)

    it "persists (masked), reconfigures, and emits :llm_provider_upserted" do
      masked = handler.call(cmd("api" => "deepseek", "api_key" => "sk-secret", "base_url" => "https://api.deepseek.com/v1"))
      expect(masked["api_key"]).to eq("__OCULTO__")
      expect(fake_config.calls["deepseek_api_key"]).to eq("sk-secret") # reconfigured with the real key
      ev = events.find { |e| e.type == :llm_provider_upserted }
      expect(ev.data[:applied]).to eq(["deepseek"])
    end
  end

  describe Insika::Commands::DeleteLLMProvider do
    subject(:handler) { described_class.new(provider_store: store, configurator: configurator, event_stream: stream) }

    def cmd(payload) = Insika::Command.build(:delete_llm_provider, payload)

    it "removes (existed: true) and emits; idempotent" do
      store.upsert("api" => "deepseek", "api_key" => "sk-1")
      expect(handler.call(cmd("api" => "deepseek"))).to eq({ existed: true })
      expect(handler.call(cmd("api" => "deepseek"))).to eq({ existed: false })
      expect(events.map(&:type)).to eq([:llm_provider_deleted, :llm_provider_deleted])
    end

    it "undoes the runtime config when it existed" do
      store.upsert("api" => "deepseek", "api_key" => "sk-1")
      configurator.apply
      handler.call(cmd("api" => "deepseek"))
      expect(fake_config.calls["deepseek_api_key"]).to be_nil # unapply zeroed it
    end

    it "undoes nothing if it did not exist (idempotent, without touching config)" do
      handler.call(cmd("api" => "fantasma"))
      expect(fake_config.calls).not_to have_key("fantasma_api_key")
    end

    it "api required" do
      expect { handler.call(cmd({})) }.to raise_error(Insika::ValidationError, /api/)
    end
  end
end

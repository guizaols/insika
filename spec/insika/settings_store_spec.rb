# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::SettingsStore do
  subject(:store) { described_class.new(config_store: config_store) }

  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }

  describe "#get" do
    it "returns DEFAULTS overlaid by authored values" do
      store.update("streaming" => false)
      merged = store.get
      expect(merged["streaming"]).to be(false)
      expect(merged["request_timeout"]).to eq(120) # untouched default
    end
  end

  describe "schema versioning (— no silent config compat)" do
    it "reports nil version when nothing is persisted (fresh deploy, nothing to migrate)" do
      expect(store.stored_schema_version).to be_nil
      expect(store.pending_migrations).to be_empty
    end

    it "stamps the current version on the first write" do
      store.update("streaming" => true)
      expect(store.stored_schema_version).to eq(described_class::SCHEMA_VERSION)
      expect(store.pending_migrations).to be_empty
    end

    it "reads a pre-versioning record as v0 with a pending migration to the baseline" do
      config_store.put("settings", "general", { "streaming" => true }) # no schema_version
      expect(store.stored_schema_version).to eq(0)
      expect(store.pending_migrations).to eq([1])
    end

    it "#migrate! stamps the baseline explicitly and is idempotent" do
      config_store.put("settings", "general", { "streaming" => true })
      expect(store.migrate!).to eq(described_class::SCHEMA_VERSION)
      expect(store.stored_schema_version).to eq(described_class::SCHEMA_VERSION)
      expect(store.pending_migrations).to be_empty
      expect(store.migrate!).to eq(described_class::SCHEMA_VERSION) # no-op the second time
    end

    it "#migrate! on a fresh store is a no-op (does not create a phantom record)" do
      expect(store.migrate!).to eq(described_class::SCHEMA_VERSION)
      expect(store.stored_schema_version).to be_nil
    end
  end
end

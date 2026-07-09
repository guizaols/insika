# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Command do
  describe ".build" do
    it "preenche meta com defaults (command_id, issued_at, transport, tenant)" do
      command = described_class.build(:cancel_task, { task_id: "x" })

      expect(command.type).to eq(:cancel_task)
      expect(command.payload).to eq({ task_id: "x" })
      expect(command.meta[:command_id]).to match(/\A[0-9a-f-]{36}\z/)
      expect { Time.iso8601(command.meta[:issued_at]) }.not_to raise_error
      expect(command.meta[:transport]).to eq(:internal)
      expect(command.meta[:tenant]).to be_nil
    end

    it "aceita overrides de transport e tenant" do
      command = described_class.build(:create_session, {}, transport: :http, tenant: "acme")

      expect(command.meta[:transport]).to eq(:http)
      expect(command.meta[:tenant]).to eq("acme")
    end

    it "normaliza type String para Symbol" do
      expect(described_class.build("cancel_task", {}).type).to eq(:cancel_task)
    end

    it "normaliza payload nil para {}" do
      expect(described_class.build(:x, nil).payload).to eq({})
    end

    it "produz um value object imutável (Data)" do
      command = described_class.build(:x, {})

      expect { command.instance_variable_set(:@payload, {}) }.to raise_error(FrozenError)
      expect(command).not_to respond_to(:payload=)
    end
  end
end

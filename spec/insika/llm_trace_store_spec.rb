# frozen_string_literal: true
require "spec_helper"
require "tmpdir"

RSpec.describe Insika::LLMTraceStore do
  [:memory, :sqlite].each do |kind|
    context kind.to_s do
      around do |example|
        Dir.mktmpdir do |dir|
          @path = File.join(dir, "trace.db")
          @backend = kind == :memory ? Insika::Stores::Memory.new : Insika::Stores::SQLite.new(path: @path)
          example.run
        ensure
          @backend.close if @backend.respond_to?(:close)
        end
      end
      let(:tasks) { Insika::TaskStore.new(store: @backend) }
      let(:store) { described_class.new(store: @backend) }
      before { tasks.create(id: "t", command: {}) }
      let(:entry) { { "type" => "llm_usage", "request_id" => "r", "model" => "m", "cost" => nil } }

      it "persists safe scalar data and preserves unknown cost" do
        store.record(task_id: "t", entry: entry.merge("messages" => "secret", "provider" => { "secret" => "x" }, "model" => "x" * 5000, "duration_ms" => Float::INFINITY))
        row = store.for_task("t").fetch("entries").first
        expect(row).to include("cost" => nil)
        expect(row).not_to have_key("messages")
        expect(row).not_to have_key("provider")
        expect(row).not_to have_key("duration_ms")
        expect(row.fetch("model").size).to be <= 256
        if kind == :sqlite
          @backend.close
          @backend = Insika::Stores::SQLite.new(path: @path)
          expect(described_class.new(store: @backend).for_task("t")["entries"]).to eq([row])
        end
      end

      it "retains the latest 200 events and discloses truncation" do
        205.times { |i| store.record(task_id: "t", entry: entry.merge("turn" => i)) }
        result = store.for_task("t")
        expect(result["truncated"]).to be(true)
        expect(result["entries"].map { |e| e["turn"] }).to eq((5...205).to_a)
      end

      it "serializes concurrent appends" do
        Sync do |parent|
          20.times.map { |i| parent.async { store.record(task_id: "t", entry: entry.merge("turn" => i)) } }.each(&:wait)
        end
        expect(store.for_task("t")["entries"].size).to eq(20)
      end

      it "cleans up on task deletion and ignores late appends" do
        store.record(task_id: "t", entry: entry)
        expect(tasks.delete("t")).to be(true)
        store.record(task_id: "t", entry: entry)
        expect(store.for_task("t")).to eq("entries" => [], "truncated" => false)
      end

      it "clears traces and tolerates missing traces" do
        expect(store.for_task("old")["entries"]).to eq([])
        store.record(task_id: "t", entry: entry)
        expect(store.clear("t")).to be(true)
      end
    end
  end

  it "does not propagate storage failures" do
    backend = double("broken backend")
    allow(backend).to receive(:transaction).and_raise("secret failure")
    expect { described_class.new(store: backend).record(task_id: "t", entry: {}) }.not_to raise_error
  end
end

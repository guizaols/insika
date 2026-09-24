# frozen_string_literal: true
require "spec_helper"
require "tmpdir"

RSpec.describe "Durable model metrics" do
  [:memory, :sqlite].each do |kind|
    context kind.to_s do
      around do |example|
        Dir.mktmpdir do |dir|
          @path = File.join(dir, "metrics.db")
          @backend = kind == :memory ? Insika::Stores::Memory.new : Insika::Stores::SQLite.new(path: @path)
          example.run
        ensure
          @backend.close if @backend.respond_to?(:close)
        end
      end
      let(:tasks) { Insika::TaskStore.new(store: @backend) }
      let(:store) { Insika::ModelMetricsStore.new(store: @backend) }
      let(:now) { Time.utc(2026, 9, 24, 12) }
      before { tasks.create(id: "t", command: {}) }

      def record(type, id: "r", task: "t", **fields)
        store.record(task_id: task, entry: {
          "type" => type, "request_id" => id, "at" => now.iso8601,
          "provider" => "deepseek", "model" => "flash"
        }.merge(fields.transform_keys(&:to_s)))
      end

      it "counts completion without usage and joins late usage without losing unknown retries" do
        record("llm_request", duration_ms: 12, status: "succeeded")
        expect(store.report(now: now)["totals"]).to include("requests" => 1, "attempts" => 0,
          "cost" => nil, "unknown_cost_requests" => 1, "p50_ms" => 12)
        record("llm_usage", status: "failed", cost: nil, input_tokens: nil)
        record("llm_usage", status: "succeeded", cost: 0, input_tokens: 8, output_tokens: 2)
        expect(store.report(now: now)["totals"]).to include("requests" => 1, "attempts" => 2,
          "retries" => 1, "failures" => 0, "failed_attempts" => 1, "cost" => 0,
          "unknown_cost_requests" => 1, "input_tokens" => 8, "unknown_input_tokens_requests" => 1,
          "cache_read_tokens" => nil)
      end

      it "keeps usage-only records out of reports until completion and persists through reopen" do
        record("llm_usage", cost: 0.5, input_tokens: 7)
        expect(store.report(now: now)["totals"]["requests"]).to eq(0)
        record("llm_request", duration_ms: 5, status: "failed", messages: "secret", exception_class: "SecretError")
        if kind == :sqlite
          @backend.close
          @backend = Insika::Stores::SQLite.new(path: @path)
        end
        result = Insika::ModelMetricsStore.new(store: @backend).report(now: now)
        expect(result["totals"]).to include("requests" => 1, "cost" => 0.5, "failures" => 1,
          "unknown_cost_requests" => 0)
        expect(JSON.generate(result)).not_to include("secret", "SecretError")
      end

      it "retains all requests past trace truncation and computes exact nearest-rank percentiles" do
        205.times do |i|
          record("llm_request", id: i.to_s, duration_ms: i + 1, status: "succeeded")
        end
        report = store.report(now: now)
        expect(report["totals"]).to include("requests" => 205, "p50_ms" => 103, "p90_ms" => 185, "p95_ms" => 195)
        expect(report["slowest"].map { |row| row["duration_ms"] }).to eq(205.downto(186).to_a)
      end

      it "filters UTC completion times and exact actual providers and models" do
        record("llm_usage", model: "fallback", cost: 0.1, cache_read_tokens: 2, cache_write_tokens: 3, thinking_tokens: 4)
        record("llm_request", model: "fallback", duration_ms: 9, status: "succeeded")
        record("llm_request", id: "old", at: (now - 2 * 86400).iso8601, provider: "other", model: "slow", duration_ms: 20)
        record("llm_request", id: "future", at: (now + 1).iso8601, duration_ms: 30)
        report = store.report(period: "24h", model: "fallback", provider: "deepseek", now: now)
        expect(report["totals"]).to include("requests" => 1, "cache_read_tokens" => 2, "cache_write_tokens" => 3, "thinking_tokens" => 4)
        expect(report["models"].first).to include("provider" => "deepseek", "model" => "fallback")
        expect(store.report(period: "7d", now: now)["totals"]["requests"]).to eq(2)
        expect(store.report(provider: "deep", now: now)["totals"]["requests"]).to eq(0)
      end

      it "isolates concurrent tasks, deletes only their records and rejects late events" do
        tasks.create(id: "t:other", command: {})
        Sync do |parent|
          %w[t t:other].map do |task|
            parent.async { record("llm_request", task: task, duration_ms: 1) }
          end.each(&:wait)
        end
        expect(tasks.delete("t")).to be(true)
        record("llm_usage", cost: 100)
        record("llm_request", duration_ms: 2)
        expect(store.report(now: now)["slowest"].map { |row| row["task_id"] }).to eq(["t:other"])
        tasks.delete("t:other")
        expect(@backend.list(Insika::ModelMetricsStore::SCOPE)).to be_empty
      end

      it "removes metrics through retention and tenant purge and does not recreate them" do
        sessions = Insika::SessionStore.new(store: @backend)
        memory = Insika::MemoryStore.new(store: @backend)
        sessions.create(id: "acme:s")
        tasks.create(id: "tenant-task", session_id: "acme:s", command: {})
        record("llm_request", task: "tenant-task", duration_ms: 3)
        Insika::Commands::DeleteTenantData.new(memory_store: memory, session_store: sessions,
          task_store: tasks, event_stream: SpyEventStream.new).call(
            Insika::Command.build(:delete_tenant_data, { tenant: "acme" }))
        record("llm_usage", task: "tenant-task", cost: 9)
        expect(store.report(now: now)["totals"]["requests"]).to eq(0)

        record("llm_request", duration_ms: 4)
        tasks.transition("t", to: :cancelled)
        old = @backend.get("tasks", "task:t").merge("updated_at" => (now - 40 * 86400).iso8601)
        @backend.set("tasks", "task:t", old)
        Insika::Retention.new(store: @backend, session_store: sessions, task_store: tasks,
          checkpoint_store: Insika::CheckpointStore.new(store: @backend), memory_store: memory,
          outcome_store: Insika::OutcomeStore.new(store: @backend),
          settings_store: Struct.new(:get).new({ "retention_days" => 30 }), now: now).run
        record("llm_usage", cost: 9)
        expect(@backend.list(Insika::ModelMetricsStore::SCOPE)).to be_empty
      end

      it "rejects missing request ids and unsafe values without interrupting callers" do
        record("llm_request", id: nil, duration_ms: 5)
        record("llm_request", id: "", duration_ms: 5)
        record("llm_request", duration_ms: Float::INFINITY, provider: { "secret" => "value" })
        record("llm_usage", cost: -1, input_tokens: "secret", output_tokens: Float::NAN)
        totals = store.report(now: now)["totals"]
        expect(totals).to include("requests" => 1, "cost" => nil, "input_tokens" => nil, "p50_ms" => nil)
      end
    end
  end
end

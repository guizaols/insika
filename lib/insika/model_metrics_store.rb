# frozen_string_literal: true

require "time"

module Insika
  # Content-free request summaries; independent of the bounded diagnostic trace.
  class ModelMetricsStore
    SCOPE = "model_metrics"
    # One row per completed turn (TurnTiming#metrics + agent/model/provider),
    # keyed by task id; TaskStore#delete drops it with the task.
    TURN_SCOPE = "turn_metrics"
    TURN_WINDOWS = %w[ttft_ms total_ms first_balloon_ms queue_ms prep_ms tools_ms].freeze
    PERIODS = { "24h" => 86_400, "7d" => 7 * 86_400, "30d" => 30 * 86_400 }.freeze
    VALUES = %w[cost input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens].freeze
    FIELDS = %w[type request_id at operation agent provider model status duration_ms turn].freeze + VALUES

    def initialize(store:)
      @store = store
    end

    def self.task_prefix(task_id) = "#{task_id.to_s.bytesize}:#{task_id}:"

    def record(task_id:, entry:) = record_many(task_id: task_id, entries: [entry])

    # A turn's events in one transaction: each request's row is read and written
    # once, however many events (request, usage, retries) it got.
    def record_many(task_id:, entries:)
      rows = entries.filter_map do |entry|
        data = LLMTraceStore.sanitize(entry.slice(*FIELDS))
        next unless %w[llm_request llm_usage].include?(data["type"])
        next if data["request_id"].nil? || data["request_id"].empty?

        data
      end
      return if rows.empty?

      @store.transaction do
        next unless @store.get(TaskStore::SCOPE, "#{TaskStore::KEY_PREFIX}#{task_id}")

        rows.group_by { |data| data["request_id"] }.each do |request_id, events|
          key = self.class.task_prefix(task_id) + request_id
          row = @store.get(SCOPE, key) || {
            "task_id" => task_id.to_s, "request_id" => request_id,
            "attempts" => 0, "failed_attempts" => 0, "reported" => {}
          }
          events.each { |data| fold(row, data) }
          @store.set(SCOPE, key, row)
        end
      end
    rescue StandardError
      nil
    end

    def record_turn(task_id:, row:)
      @store.set(TURN_SCOPE, task_id.to_s, row)
    rescue StandardError
      nil
    end

    # `from`/`to` (Time) pick a custom range and win over `period`; the bucket size
    # follows the span (see #bucket_count).
    def report(period: "7d", agent: nil, provider: nil, model: nil, now: Time.now.utc, from: nil, to: nil)
      if from && to
        period, now = "custom", to
      else
        period = "7d" unless PERIODS.key?(period)
        from = now - PERIODS.fetch(period)
      end
      # ponytail: whole-scope scan suits a single node; index completion time when history grows.
      rows = @store.list(SCOPE).filter_map do |key|
        row = @store.get(SCOPE, key)
        next unless row && row["completed_at"]

        completed = Time.iso8601(row["completed_at"])
        row if completed >= from && completed <= now
      end
      agents = rows.filter_map { |row| row["agent"] }.uniq.sort
      providers = rows.filter_map { |row| row["provider"] }.uniq.sort
      model_options = rows.filter_map { |row| row["model"] }.uniq.sort
      rows.select! do |row|
        (agent.nil? || row["agent"] == agent) &&
          (provider.nil? || row["provider"] == provider) && (model.nil? || row["model"] == model)
      end
      {
        "period" => period, "from" => from.utc.iso8601, "to" => now.utc.iso8601,
        "step_seconds" => ((now - from) / bucket_count(period, now - from)).round,
        "agents" => agents, "providers" => providers, "model_options" => model_options,
        "totals" => summarize(rows),
        "series" => time_series(rows, from: from, to: now, period: period),
        "models" => rows.group_by { |row| [row["provider"], row["model"]] }
          .sort_by { |key, _| key.map(&:to_s) }.map do |(name, model_name), group|
            summarize(group).merge("provider" => name, "model" => model_name)
          end,
        # The same model serves the reply and the post-turn learning: this splits
        # their cost ("chat" vs knowledge_*). Rows from before labeling read as "chat".
        "operations" => rows.group_by { |row| row["operation"] || "chat" }.sort.map do |operation, group|
          summarize(group).merge("operation" => operation)
        end,
        "turns" => turn_report(from, now, agent: agent, provider: provider, model: model),
        "slowest" => rows.select { |row| row["duration_ms"] }.sort_by { |row| -row["duration_ms"] }
          .first(20).map { |row| row.reject { |key, _| key == "reported" }.merge(summarize([row])) },
        "history_note" => "History starts with deployment. Deleting a task removes its model history."
      }
    end

    private

    # Turn latency (each window's p50/p95) and per-tool health over the turn rows.
    def turn_report(from, to, agent:, provider:, model:)
      # ponytail: whole-scope scan like #report; index by time when history grows.
      turns = @store.list(TURN_SCOPE).filter_map do |key|
        row = @store.get(TURN_SCOPE, key)
        next unless row && row["at"]

        at = Time.iso8601(row["at"])
        next unless at >= from && at <= to
        next unless (agent.nil? || row["agent"] == agent) &&
                    (provider.nil? || row["provider"] == provider) && (model.nil? || row["model"] == model)

        row
      end
      windows = TURN_WINDOWS.to_h do |window|
        values = turns.filter_map { |row| row[window] }.sort
        [window, { "measured" => values.size, "p50" => percentile(values, 50), "p95" => percentile(values, 95) }]
      end
      tools = turns.flat_map { |row| Array(row["tools"]) }.group_by(&:first).sort.map do |name, calls|
        ms = calls.filter_map { |call| call[2] }.sort
        { "tool" => name, "calls" => calls.size, "failures" => calls.count { |call| call[1] == false },
          "p50_ms" => percentile(ms, 50), "p95_ms" => percentile(ms, 95) }
      end
      failed = turns.select { |row| row["status"] == "failed" }
      { "count" => turns.size, "failures" => failed.size,
        "failure_stages" => failed.group_by { |row| row["stage"] || "unknown" }.transform_values(&:size).sort.to_h,
        "windows" => windows, "tools" => tools }
    end

    # Nearest rank on a sorted list; nil when empty.
    def percentile(sorted, pct) = sorted.empty? ? nil : sorted[(sorted.size * pct / 100.0).ceil - 1]

    def fold(row, data)
      row.merge!(data.slice("operation", "agent", "provider", "model", "turn").compact)
      if data["type"] == "llm_request"
        row.merge!(data.slice("status", "duration_ms"))
        row["completed_at"] = Time.iso8601(data.fetch("at")).utc.iso8601(6)
      else
        row["attempts"] += 1
        row["failed_attempts"] += 1 if data["status"] == "failed"
        VALUES.each do |field|
          next if data[field].nil?

          row[field] = row.fetch(field, 0) + data[field]
          row["reported"][field] = row["reported"].fetch(field, 0) + 1
        end
      end
    end

    HOUR = 3600
    MAX_BUCKETS = 92

    # Fixed periods keep their buckets; a custom range goes hourly up to 2 days,
    # 6-hourly up to 14, daily beyond (capped, so a year stays a readable chart).
    def bucket_count(period, span)
      fixed = { "24h" => 24, "7d" => 28, "30d" => 30 }[period]
      return fixed if fixed

      base = if span <= 48 * HOUR then HOUR elsif span <= 14 * 24 * HOUR then 6 * HOUR else 24 * HOUR end
      (span / base).ceil.clamp(1, MAX_BUCKETS)
    end

    def time_series(rows, from:, to:, period:)
      count = bucket_count(period, to - from)
      step = (to - from) / count
      buckets = Array.new(count) { [] }
      rows.each do |row|
        index = [((Time.iso8601(row["completed_at"]) - from) / step).floor, count - 1].min
        buckets[index] << row
      end
      buckets.each_with_index.map do |group, index|
        summarize(group).merge("at" => (from + index * step).utc.iso8601,
          "until" => (from + (index + 1) * step).utc.iso8601)
      end
    end

    def summarize(rows)
      durations = rows.filter_map { |row| row["duration_ms"] }.sort
      result = {
        "requests" => rows.size, "attempts" => rows.sum { |row| row["attempts"] },
        "failures" => rows.count { |row| row["status"] == "failed" },
        "failed_attempts" => rows.sum { |row| row["failed_attempts"] },
        "retries" => rows.sum { |row| [row["attempts"] - 1, 0].max },
        "measured_requests" => durations.size
      }
      [50, 90, 95].each { |pct| result["p#{pct}_ms"] = percentile(durations, pct) }
      VALUES.each do |field|
        values = rows.filter_map { |row| row[field] }
        result[field] = values.empty? ? nil : values.sum
        result["unknown_#{field}_requests"] = rows.count do |row|
          row["attempts"].zero? || row["reported"].fetch(field, 0) < row["attempts"]
        end
      end
      result
    end
  end
end

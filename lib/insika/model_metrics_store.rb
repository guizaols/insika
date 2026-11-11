# frozen_string_literal: true

require "time"

module Insika
  # Content-free request summaries; independent of the bounded diagnostic trace.
  class ModelMetricsStore
    SCOPE = "model_metrics"
    # One row per completed turn (TurnTiming#metrics + agent/model/provider),
    # keyed by task id; TaskStore#delete drops it with the task.
    TURN_SCOPE = "turn_metrics"
    # One row per closed UTC day the home charts: cost and requests, keyed "agent|YYYY-MM-DD"
    # ("*" = every agent). See #home.
    DAY_SCOPE = "model_metrics_day"
    # One row per closed UTC day per agent ("agent|YYYY-MM-DD"; "*" = every agent,
    # and marks the day as kept) of what #windows adds up: counts, and latencies as
    # histograms so days merge into a 7d/30d percentile. No session ids.
    # ponytail: never pruned, like DAY_SCOPE; a task deleted later still counts.
    WINDOW_DAY_SCOPE = "model_metrics_window_day"
    # Each histogram bucket is 10% wider than the one before, so a merged percentile
    # lands within 5% of the exact one.
    BUCKET_GROWTH = 1.1
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

    # One agent's (or everyone's) totals and turn summary for each fixed period.
    # 24h is exact, from the rows. 7d and 30d are today plus the 7 (or 30) whole
    # UTC days before it: the rows since yesterday's start, plus the older days
    # kept in WINDOW_DAY_SCOPE. A period costs 48h of rows however busy the store,
    # and its latency percentiles come from per-day histograms (see #histogram).
    # -> { "24h" => { "totals", "turns" }, ... }
    def windows(agent: nil, now: Time.now.utc)
      today = Time.utc(now.year, now.month, now.day)
      raw_from = today - 86_400
      rows = request_rows(raw_from, now).select { |row| agent.nil? || row["agent"] == agent }
      turns = turn_rows(raw_from, now, agent: agent, provider: nil, model: nil)
      day_ago = now - 86_400
      kept = window_days(agent, today - PERIODS.values.max, raw_from)
      PERIODS.to_h do |period, seconds|
        next [period, { "totals" => summarize(rows.select { |row| Time.iso8601(row["completed_at"]) >= day_ago }),
                        "turns" => turn_summary(turns.select { |row| Time.iso8601(row["at"]) >= day_ago }) }] if seconds <= 86_400

        days = kept.select { |day, _| day >= today - seconds }.map(&:last)
        [period, { "totals" => merged_totals(rows, days), "turns" => merged_turns(turns, days) }]
      end
    end

    # Everything the Studio home shows: the last 24h (totals + turns), the cost
    # of the 24h before, and one bucket per UTC day (oldest first, today last).
    # Rows are read for the last 48h only. A day that ended before that never
    # changes again, so its cost and request count are kept in DAY_SCOPE the first
    # time a home needs it: 14 days of rows, scattered across a big file, cost
    # seconds on a cold disk.
    # ponytail: day rows are never pruned (one per day per agent); a task deleted
    # later still counts in a kept day.
    def home(agent: nil, now: Time.now.utc, days: 14)
      today = Time.utc(now.year, now.month, now.day)
      day_ago = now - 86_400
      recent_from = day_ago - 86_400
      day_starts = Array.new(days) { |i| today - (days - 1 - i) * 86_400 }
      tag = "#{agent || '*'}|"
      kept = @store.entries(DAY_SCOPE, tag).to_h { |key, value| [key.delete_prefix(tag), value] }
      missing = day_starts.select { |day| day + 86_400 <= recent_from && !kept.key?(day.strftime("%F")) }
      timed = request_rows([recent_from, *missing].min, now)
        .select { |row| agent.nil? || row["agent"] == agent }
        .map { |row| [row, Time.iso8601(row["completed_at"])] }
      by_day = timed.group_by { |_, t| t.strftime("%F") }.transform_values { |pairs| pairs.map(&:first) }
      day_total = ->(key) { summarize(by_day.fetch(key, [])).slice("cost", "requests") }
      fresh = missing.to_h { |day| [day.strftime("%F"), day_total.(day.strftime("%F"))] }
      keep_days(tag, fresh)
      {
        "totals" => summarize(timed.filter_map { |row, t| row if t >= day_ago }),
        "turns" => turn_summary(turn_rows(day_ago, now, agent: agent, provider: nil, model: nil)),
        "day_before_cost" => summarize(timed.filter_map { |row, t| row if t >= recent_from && t < day_ago })["cost"],
        "daily" => day_starts.map do |day|
          key = day.strftime("%F")
          (kept[key] || fresh[key] || day_total.(key)).merge("at" => day.iso8601)
        end
      }
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
      rows = request_rows(from, now)
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

    REPRICE_BATCH = 500
    REPRICE_EPSILON = 1e-12 # float noise is not a price change

    # Corrects the cost of the request rows completed in [from, to]. The block
    # gets a row and returns its cost, or nil to leave it; a row whose cost is
    # unknown stays unknown. A corrected row keeps its place in the write order
    # (#pairs_between pages by it), and the day summaries that already counted it
    # move by the same difference in the same transaction, so a day whose rows
    # were deleted since keeps their share. Running it twice changes nothing more.
    # -> { "rows", "changed", "before", "after" } (USD over the changed rows);
    # nothing is written unless `apply`.
    def reprice(from:, to:, apply: false)
      pairs = pairs_between(SCOPE, "completed_at", from, to)
      changes = pairs.filter_map do |key, row|
        next unless row["cost"].is_a?(Numeric)

        cost = yield(row)
        [key, row, cost] if cost.is_a?(Numeric) && (cost - row["cost"]).abs > REPRICE_EPSILON
      end
      result = { "rows" => pairs.size, "changed" => changes.size,
                 "before" => changes.sum { |_, row, _| row["cost"] }, "after" => changes.sum { |_, _, cost| cost } }
      return result unless apply

      changes.each_slice(REPRICE_BATCH) do |batch|
        @store.transaction do
          days = Hash.new(0.0)
          batch.each do |key, row, cost|
            next unless @store.get(SCOPE, key) == row # written since it was read: the next run takes it

            @store.amend(SCOPE, key, row.merge("cost" => cost))
            day = Time.iso8601(row["completed_at"]).utc.strftime("%F")
            ["*", row["agent"]].compact.each { |tag| days["#{tag}|#{day}"] += cost - row["cost"] }
          end
          days.each { |key, delta| shift_kept_day(key, delta) }
        end
      end
      result
    end

    private

    # a failed write only means the next home computes those days again
    def keep_days(tag, days)
      return if days.empty?

      @store.transaction { days.each { |key, value| @store.set(DAY_SCOPE, "#{tag}#{key}", value) } }
    rescue StandardError
      nil
    end

    def request_rows(from, to) = rows_between(SCOPE, "completed_at", from, to)

    RECENT_PAGE = 500
    # A row is written when its turn ends (or flushes before waiting), so its
    # write can trail its own timestamp by up to a turn. Paging stops only past
    # this margin, so a late write is never cut off.
    LATE_WRITE = 6 * 3600

    # The rows whose `field` falls in [from, to], read newest-written first and
    # stopping at the first page entirely older than `from` (minus LATE_WRITE):
    # a window costs its own rows, not the whole history. The stop test reads the
    # page's oldest RECENT_PAGE rows, so a doubled page stops as early as a small one.
    # ponytail: offset paging over write order; a time-keyed index if windows reach far back.
    def rows_between(scope, field, from, to) = pairs_between(scope, field, from, to).map(&:last)

    # #rows_between with each row's key: [[key, row], ...].
    def pairs_between(scope, field, from, to)
      floor = from - LATE_WRITE
      pairs = []
      offset = 0
      limit = RECENT_PAGE
      loop do
        page = @store.recent(scope, nil, limit, offset)
        times = page.map { |_key, row| row.is_a?(Hash) && row[field] ? Time.iso8601(row[field]) : nil }
        page.each_with_index { |pair, i| pairs << pair if times[i] && times[i] >= from && times[i] <= to }
        break if page.size < limit || times.last(RECENT_PAGE).all? { |t| t && t < floor }

        offset += limit
        limit *= 2 # each call orders the whole scope: few big pages, not many small ones
      end
      pairs
    end

    # Moves the kept summaries of one "agent|YYYY-MM-DD" by a cost difference.
    # A day nobody kept yet has nothing to move: it is summarized from the rows.
    def shift_kept_day(key, delta)
      day = @store.get(DAY_SCOPE, key)
      @store.set(DAY_SCOPE, key, day.merge("cost" => day["cost"] + delta)) if day && day["cost"].is_a?(Numeric)
      window = @store.get(WINDOW_DAY_SCOPE, key)
      return unless window && window.dig("totals", "cost").is_a?(Numeric)

      totals = window["totals"].merge("cost" => window["totals"]["cost"] + delta)
      @store.set(WINDOW_DAY_SCOPE, key, window.merge("totals" => totals))
    end

    def turn_report(from, to, agent:, provider:, model:)
      turn_summary(turn_rows(from, to, agent: agent, provider: provider, model: model))
    end

    def turn_rows(from, to, agent:, provider:, model:)
      rows_between(TURN_SCOPE, "at", from, to).select do |row|
        (agent.nil? || row["agent"] == agent) &&
          (provider.nil? || row["provider"] == provider) && (model.nil? || row["model"] == model)
      end
    end

    FAILED_SESSIONS = 5 # newest sessions listed per failing tool

    # Turn latency (each window's p50/p95) and per-tool health over turn rows.
    def turn_summary(turns)
      windows = TURN_WINDOWS.to_h do |window|
        values = turns.filter_map { |row| row[window] }.sort
        [window, { "measured" => values.size, "p50" => percentile(values, 50), "p95" => percentile(values, 95) }]
      end
      # each call carries its turn's session, so a failing tool links to where it failed
      calls = turns.flat_map { |row| Array(row["tools"]).map { |call| call.first(3) + [row["session"]] } }
      tools = calls.group_by(&:first).sort.map do |name, list|
        ms = list.filter_map { |call| call[2] }.sort
        failed = list.select { |call| call[1] == false }
        { "tool" => name, "calls" => list.size, "failures" => failed.size,
          "p50_ms" => percentile(ms, 50), "p95_ms" => percentile(ms, 95),
          "failed_sessions" => failed.filter_map(&:last).uniq.first(FAILED_SESSIONS) }
      end
      failed = turns.select { |row| row["status"] == "failed" }
      { "count" => turns.size, "failures" => failed.size,
        "failure_stages" => failed.group_by { |row| row["stage"] || "unknown" }.transform_values(&:size).sort.to_h,
        "windows" => windows, "tools" => tools }
    end

    COUNTS = %w[requests attempts failures failed_attempts retries measured_requests].freeze

    # The kept days in [from, to), oldest first: [[day, summary], ...]. A day nobody
    # kept yet is summarized from its rows once, for every agent at the same time.
    def window_days(agent, from, to)
      days = []
      (days << from; from += 86_400) while from < to
      done = @store.entries(WINDOW_DAY_SCOPE, "*|").to_h { |key, value| [key.delete_prefix("*|"), value] }
      tag = "#{agent || '*'}|"
      kept = agent ? @store.entries(WINDOW_DAY_SCOPE, tag).to_h { |key, value| [key.delete_prefix(tag), value] } : done
      fresh = keep_window_days(days.reject { |day| done.key?(day.strftime("%F")) })
      days.map do |day|
        key = day.strftime("%F")
        [day, fresh.dig(key, agent || "*") || kept[key] || day_summary([], [])]
      end
    end

    # -> { "YYYY-MM-DD" => { agent => summary, "*" => summary } } for the given days.
    def keep_window_days(days)
      return {} if days.empty?

      from, to = days.min, days.max + 86_400
      wanted = days.to_set { |day| day.strftime("%F") }
      by_day = ->(list, field) { list.group_by { |row| Time.iso8601(row[field]).utc.strftime("%F") } }
      rows = by_day.(request_rows(from, to), "completed_at")
      turns = by_day.(rows_between(TURN_SCOPE, "at", from, to), "at")
      fresh = wanted.to_h do |key|
        day_rows, day_turns = rows.fetch(key, []), turns.fetch(key, [])
        agents = (day_rows + day_turns).filter_map { |row| row["agent"] }.uniq
        [key, agents.to_h do |name|
          [name, day_summary(day_rows.select { |row| row["agent"] == name }, day_turns.select { |row| row["agent"] == name })]
        end.merge("*" => day_summary(day_rows, day_turns))]
      end
      @store.transaction do
        fresh.each { |key, summaries| summaries.each { |name, summary| @store.set(WINDOW_DAY_SCOPE, "#{name}|#{key}", summary) } }
      end
      fresh
    rescue StandardError
      fresh || {} # a failed write only means the next read summarizes those days again
    end

    def day_summary(rows, turns)
      calls = turns.flat_map { |row| Array(row["tools"]) }
      failed = turns.select { |row| row["status"] == "failed" }
      { "totals" => summarize(rows).except("p50_ms", "p90_ms", "p95_ms")
                                   .merge("durations" => histogram(rows.filter_map { |row| row["duration_ms"] })),
        "turns" => { "count" => turns.size, "failures" => failed.size,
                     "failure_stages" => failed.group_by { |row| row["stage"] || "unknown" }.transform_values(&:size),
                     "windows" => TURN_WINDOWS.to_h { |window| [window, histogram(turns.filter_map { |row| row[window] })] },
                     "tools" => calls.group_by(&:first).transform_values do |list|
                       { "calls" => list.size, "failures" => list.count { |call| call[1] == false },
                         "ms" => histogram(list.filter_map { |call| call[2] }) }
                     end } }
    end

    # The rows' summary plus the kept days', in #summarize's shape.
    def merged_totals(rows, days)
      result = summarize(rows)
      totals = days.map { |day| day["totals"] }
      COUNTS.each { |field| result[field] += totals.sum { |t| t[field].to_i } }
      VALUES.each do |field|
        values = [result[field], *totals.map { |t| t[field] }].compact
        result[field] = values.empty? ? nil : values.sum
        result["unknown_#{field}_requests"] += totals.sum { |t| t["unknown_#{field}_requests"].to_i }
      end
      hist = merge_histograms([histogram(rows.filter_map { |row| row["duration_ms"] }), *totals.map { |t| t["durations"] }])
      [50, 90, 95].each { |pct| result["p#{pct}_ms"] = histogram_percentile(hist, pct) }
      result
    end

    # The turns' summary plus the kept days', in #turn_summary's shape. Failed
    # sessions come from the recent turns only (days keep no session ids).
    def merged_turns(turns, days)
      result = turn_summary(turns)
      kept = days.map { |day| day["turns"] }
      result["count"] += kept.sum { |t| t["count"].to_i }
      result["failures"] += kept.sum { |t| t["failures"].to_i }
      result["failure_stages"] = ([result["failure_stages"]] + kept.map { |t| t["failure_stages"] || {} })
                                 .reduce { |a, b| a.merge(b) { |_, x, y| x + y } }.sort.to_h
      result["windows"] = TURN_WINDOWS.to_h do |window|
        hist = merge_histograms([histogram(turns.filter_map { |row| row[window] }), *kept.map { |t| t.dig("windows", window) }])
        [window, { "measured" => hist.values.sum, "p50" => histogram_percentile(hist, 50), "p95" => histogram_percentile(hist, 95) }]
      end
      recent = result["tools"].to_h { |tool| [tool["tool"], tool] }
      calls = turns.flat_map { |row| Array(row["tools"]) }.group_by(&:first)
      names = (recent.keys + kept.flat_map { |t| (t["tools"] || {}).keys }).uniq.sort
      result["tools"] = names.map do |name|
        days_tool = kept.filter_map { |t| t.dig("tools", name) }
        hist = merge_histograms([histogram(Array(calls[name]).filter_map { |call| call[2] }), *days_tool.map { |t| t["ms"] }])
        { "tool" => name, "calls" => recent.dig(name, "calls").to_i + days_tool.sum { |t| t["calls"] },
          "failures" => recent.dig(name, "failures").to_i + days_tool.sum { |t| t["failures"] },
          "p50_ms" => histogram_percentile(hist, 50), "p95_ms" => histogram_percentile(hist, 95),
          "failed_sessions" => recent.dig(name, "failed_sessions") || [] }
      end
      result
    end

    # Latencies as { bucket => count }; bucket 0 holds values under 1 ms, bucket k
    # the values in [GROWTH^(k-1), GROWTH^k). String keys, as JSON stores them.
    def histogram(values)
      values.each_with_object(Hash.new(0)) do |ms, hist|
        hist[ms < 1 ? "0" : (Math.log(ms) / Math.log(BUCKET_GROWTH)).floor.succ.to_s] += 1
      end
    end

    def merge_histograms(list) = list.compact.reduce({}) { |a, b| a.merge(b) { |_, x, y| x + y } }

    # Nearest rank over a histogram: the bucket's midpoint (geometric), in ms.
    def histogram_percentile(hist, pct)
      total = hist.values.sum
      return nil if total.zero?

      rank = (total * pct / 100.0).ceil
      seen = 0
      bucket = hist.keys.map(&:to_i).sort.find { |k| (seen += hist[k.to_s]) >= rank }
      bucket.zero? ? 0 : (BUCKET_GROWTH**(bucket - 0.5)).round
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

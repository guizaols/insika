# frozen_string_literal: true

require "time"

module Insika
  # The tool AUDIT the per-session trace cannot answer: `tool_traces` records
  # every call, but one session at a time, and nothing aggregates — so "which
  # tools does this agent carry and never use?" had no surface at all. This
  # report is that surface. Read-only by design: it names the candidates, the
  # OPERATOR removes (a tool the report flags may still be the one a rare but
  # critical flow needs).
  #
  # Attribution rides the task record: a session does not stamp its agent, but
  # every task carries the agent in its command payload — tasks → sessions →
  # tool_traces is the same read the Studio does. Three findings per agent:
  #
  #   never_called — in `tools_allow`, zero calls in any stored trace. Dead
  #                  weight: it costs schema tokens on every request and buys
  #                  nothing (the pilot's `search_orders` is the known example).
  #   error_rate   — called inside the window with > 30% conventional errors
  #                  (the trace's own `ok` flag). Either the tool is broken or
  #                  the model cannot hold its contract; both are operator work.
  #   stale        — called at some point, but not once inside the window.
  #
  # Bounded and honest: it reads only what the stores kept (the trace caps at
  # 200 entries/session), so a count here is "at least", never an exact total.
  class ToolUsageReport
    WINDOW_DAYS = 14
    ERROR_RATE_THRESHOLD = 0.30

    # One finding. kind: "never_called" | "error_rate" | "stale".
    Row = Data.define(:agent, :tool, :kind, :detail) do
      def to_h = { "agent" => agent, "tool" => tool, "kind" => kind, "detail" => detail }
    end

    Report = Data.define(:generated_at, :days, :agents, :rows) do
      def to_h
        { "generated_at" => generated_at, "days" => days, "agents" => agents,
          "rows" => rows.map(&:to_h) }
      end

      # Human report, grouped by agent. Silent agents still print their header —
      # "nothing flagged" is a result, not an omission.
      def to_s
        lines = ["tool usage — last #{days} day(s), generated #{generated_at}"]
        agents.each do |agent|
          mine = rows.select { |r| r.agent == agent }
          lines << "" << "#{agent}: #{mine.empty? ? 'nothing flagged' : "#{mine.length} finding(s)"}"
          mine.each { |r| lines << format("  %-13s %s — %s", r.kind, r.tool, r.detail) }
        end
        lines.join("\n")
      end
    end

    def initialize(task_store:, tool_trace_store:, profile_source:, now: nil)
      @task_store = task_store
      @tool_trace_store = tool_trace_store
      @profile_source = profile_source
      @now = now
    end

    # -> Report. `agent:` narrows to one agent (must still be a stored profile).
    def generate(days: WINDOW_DAYS, agent: nil)
      now = @now || Time.now.utc
      cutoff = now - (days * 24 * 60 * 60)
      profiles = @profile_source.all_raw
      profiles = profiles.select { |r| r["id"].to_s == agent.to_s } if agent
      sessions = sessions_by_agent

      rows = profiles.flat_map do |record|
        id = record["id"].to_s
        stats = tool_stats(sessions[id] || [], cutoff)
        never_called_rows(id, record, stats) +
          error_rate_rows(id, stats, days) +
          stale_rows(id, stats)
      end

      Report.new(generated_at: now.iso8601, days: days,
                 agents: profiles.map { |r| r["id"].to_s }.sort,
                 rows: rows.sort_by { |r| [r.agent, r.kind, r.tool] }.freeze)
    end

    private

    # agent id -> [session ids], via the task records (the only place a session
    # is tied to its agent). A task without agent or session (operator commands,
    # workflows without a chat) contributes nothing.
    def sessions_by_agent
      acc = Hash.new { |h, k| h[k] = [] }
      @task_store.each_id do |task_id|
        task = @task_store.find(task_id) or next
        agent = task.command.is_a?(Hash) ? task.command.dig("payload", "agent") : nil
        next if agent.to_s.empty? || task.session_id.to_s.empty?

        acc[agent.to_s] << task.session_id
      end
      acc.transform_values(&:uniq)
    end

    # tool name -> { calls:, errors:, window_calls:, window_errors:, last_at: }
    # over every stored trace entry of the agent's sessions.
    def tool_stats(session_ids, cutoff)
      stats = Hash.new { |h, k| h[k] = { calls: 0, errors: 0, window_calls: 0, window_errors: 0, last_at: nil } }
      session_ids.each do |sid|
        @tool_trace_store.for_session(sid).each do |entry|
          s = stats[entry["tool"].to_s]
          at = parse_time(entry["at"])
          error = entry["ok"] == false
          s[:calls] += 1
          s[:errors] += 1 if error
          s[:last_at] = at if at && (s[:last_at].nil? || at > s[:last_at])
          next unless at && at >= cutoff

          s[:window_calls] += 1
          s[:window_errors] += 1 if error
        end
      end
      stats
    end

    def never_called_rows(agent, record, stats)
      allow = record["tools_allow"]
      return [] if allow.nil? # no allowlist declared -> nothing to audit against

      Array(allow).map(&:to_s).reject { |t| stats.key?(t) }.map do |tool|
        Row.new(agent: agent, tool: tool, kind: "never_called",
                detail: "in tools_allow, never called in any stored trace — " \
                        "its schema still ships on every request")
      end
    end

    def error_rate_rows(agent, stats, days)
      stats.filter_map do |tool, s|
        next if s[:window_calls].zero?

        rate = s[:window_errors].to_f / s[:window_calls]
        next if rate <= ERROR_RATE_THRESHOLD

        Row.new(agent: agent, tool: tool, kind: "error_rate",
                detail: "#{s[:window_errors]}/#{s[:window_calls]} call(s) errored in the last " \
                        "#{days} day(s) (#{(rate * 100).round}%)")
      end
    end

    def stale_rows(agent, stats)
      stats.filter_map do |tool, s|
        next if s[:window_calls].positive? || s[:last_at].nil?

        Row.new(agent: agent, tool: tool, kind: "stale",
                detail: "last called #{s[:last_at].iso8601}, not once inside the window")
      end
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end
  end
end

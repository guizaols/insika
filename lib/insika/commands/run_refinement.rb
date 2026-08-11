# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: reads a window of the agent's real traffic
    # and records a ranked failure REPORT. Synchronous — it only scans durable stores
    # (no provider call, no fiber), so it answers with the Run and does not create a
    # Task. It is the ONLY way a refinement run starts: the CLI, the Studio button
    # and any external cron all dispatch this one command (there is no
    # scheduler in the engine).
    #
    # Payload:
    #   agent          (required) agent id
    #   since          ISO8601 — only turns from this instant on
    #   last_sessions  Integer — the N most recent conversations instead
    #   full           truthy — ignore the previous run and use the full window
    #   max_findings   Integer cap on the report
    #   exclude_sessions [prefix] — session ids to drop (load tests, debug traffic)
    #
    # Window resolution (first that applies): explicit payload -> INCREMENTAL (since
    # the previous run for this agent, unless `full`) -> the agent's configured
    # `refinement.window` -> the collector's default.
    #
    # writes NOTHING to the agent, so it needs no opt-in: an absent
    # `refinement` config reads as report-only. Only `propose`/`auto_apply`
    # require the operator to enable them explicitly.
    class RunRefinement
      READ_ONLY_MODES = %w[report propose auto_apply].freeze

      def initialize(profiles:, refinement_store:, collector:, event_stream:)
        @profiles = ProfileSource.coerce(profiles)
        @refinement_store = refinement_store
        @collector = collector
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        agent = AgentPayload.presence(p[:agent])
        raise Insika::ValidationError, "agent is required" if agent.nil?

        profile = @profiles[agent] ||
                  (raise Insika::NotFoundError, "agent '#{agent}' not configured")
        config = refinement_config(profile)
        validate_mode!(config)

        window = resolve_window(agent, p, config)
        run = @refinement_store.create(agent_id: agent, window: window)
        emit(:refinement_started, agent: agent, run_id: run.id, window: window)

        begin
          report = @collector.collect(
            agent_id: agent, max_findings: max_findings(p, config),
            exclude_sessions: exclude_sessions(p, config), **collect_args(window)
          )
          done = @refinement_store.complete(run.id, findings: report.findings,
                                            excluded: report.excluded)
          emit(:refinement_report, agent: agent, run_id: run.id, status: done.status,
                                   findings: done.findings_count,
                                   sessions: report.sessions_seen, turns: report.turns_seen,
                                   excluded: report.excluded)
          done
        rescue StandardError => e
          @refinement_store.fail(run.id, error: e.message)
          raise
        end
      end

      private

      def refinement_config(profile)
        raw = profile.respond_to?(:refinement) ? profile.refinement : nil
        raw.is_a?(Hash) ? raw : {}
      end

      # An unknown mode is a config typo, and a typo that silently degrades to
      # "report" would be the kind of quiet wrong the strict-config rule exists to
      # prevent.
      def validate_mode!(config)
        mode = AgentPayload.presence(config["mode"]) || "report"
        return if READ_ONLY_MODES.include?(mode)

        raise Insika::ValidationError,
              "unknown refinement mode: #{mode} (expected #{READ_ONLY_MODES.join(', ')})"
      end

      def resolve_window(agent, payload, config)
        since = AgentPayload.presence(payload[:since])
        return { "since" => since } if since
        return { "last_sessions" => Integer(payload[:last_sessions]) } if payload[:last_sessions]

        # `full` arrives as true (internal dispatch) or "1" (Studio form) — one
        # reading of a boolean, the same one item #131 settled on.
        unless Insika::EnvSchema.truthy?(payload[:full])
          previous = @refinement_store.latest_for(agent)
          return { "since" => previous.started_at } if previous&.started_at
        end

        configured = config.dig("window", "last_sessions")
        configured ? { "last_sessions" => Integer(configured) } : {}
      end

      # Window (as recorded) -> collector kwargs. {} = the collector's own default.
      def collect_args(window)
        return { since: window["since"] } if window["since"]
        return { last_sessions: window["last_sessions"] } if window["last_sessions"]

        {}
      end

      def max_findings(payload, config)
        raw = payload[:max_findings] || config["max_findings"]
        raw ? Integer(raw) : Refinement::EvidenceCollector::DEFAULT_MAX_FINDINGS
      end

      # Session-id prefixes to drop (load tests, debug conversations). Configured per
      # agent; a payload list overrides it for one run. Never defaulted — the report
      # does not get to decide what counts as real traffic.
      def exclude_sessions(payload, config)
        Array(payload[:exclude_sessions] || config["exclude_sessions"]).map(&:to_s)
      end

      def emit(type, **data)
        @event_stream.emit(Insika::Event.new(
                             type: type, data: data,
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end

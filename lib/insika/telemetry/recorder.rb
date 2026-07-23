# frozen_string_literal: true

require "time"

module Insika
  module Telemetry
    # Translates the harness Event Stream into OTEL SPANS — the already-existing
    # observability spine becomes traces without touching the core (Events observe; Telemetry only
    # consumes). One span per TURN (harness.turn) with child spans per tool
    # (harness.tool / harness.data_tool), correlated by task_id. Latency comes
    # from the span duration; tokens/cost and agent/model come from the ATTRIBUTES — the
    # backend (SigNoz/Tempo/…) aggregates them into metrics. Without depending on the metrics SDK.
    #
    # PURE/testable: talks to a DUCK-TYPED `tracer` (start_span/set_attribute/
    # record_error/finish) — the real OTEL adapter is injected in Telemetry.setup, a
    # fake in tests. Does NOT reference OpenTelemetry:: (loads without the gem).
    #
    # Robust: `record` NEVER raises (telemetry doesn't bring down a turn). Timestamps
    # come from each event's `meta.at` (spans reconstructed with real time).
    class Recorder
      Turn = Struct.new(:span, :tools) # tools = FIFO queue of open tool spans

      # Ceiling of open turns: a kill -9 without a terminal event would leave the turn
      # hanging; when exceeded, the oldest is closed (defensive, bounded memory).
      MAX_OPEN = 1_000

      def initialize(tracer:)
        @tracer = tracer
        @turns = {}
      end

      def record(event)
        meta = event.meta || {}
        data = event.data || {}
        case event.type
        when :task_started   then start_turn(meta, data)
        when :tool_call      then start_tool(meta, data)
        when :tool_result    then finish_tool(meta)
        when :data_tool_call then point_tool(meta, data)
        when :task_completed then finish_turn(meta, data, :ok)
        when :task_failed    then finish_turn(meta, data, :error)
        when :task_cancelled then finish_turn(meta, data, :cancelled)
        end
        nil
      rescue StandardError
        nil # telemetry NEVER brings down the consumer/turn
      end

      private

      def start_turn(meta, data)
        id = meta[:task_id] or return
        evict_oldest if @turns.size >= MAX_OPEN
        span = @tracer.start_span(
          "harness.turn", parent: nil, start_time: ts(meta[:at]),
          attributes: attrs("harness.task_id" => id, "harness.session_id" => meta[:session_id],
                            "harness.agent" => data[:agent], "harness.command" => data[:command]&.to_s)
        )
        @turns[id] = Turn.new(span, [])
      end

      def start_tool(meta, data)
        turn = @turns[meta[:task_id]] or return
        span = @tracer.start_span("harness.tool", parent: turn.span, start_time: ts(meta[:at]),
                                  attributes: attrs("harness.tool" => data[:name]&.to_s))
        turn.tools << span
      end

      # FIFO: the model calls a tool and receives the result before the next one, so
      # the result matches the first open tool span of the turn.
      def finish_tool(meta)
        turn = @turns[meta[:task_id]] or return
        span = turn.tools.shift or return
        span.finish(end_time: ts(meta[:at]))
      end

      # data-tool emits a single event (name + HTTP status) -> point span.
      def point_tool(meta, data)
        turn = @turns[meta[:task_id]] or return
        at = ts(meta[:at])
        span = @tracer.start_span("harness.data_tool", parent: turn.span, start_time: at,
                                  attributes: attrs("harness.tool" => data[:tool]&.to_s,
                                                    "harness.http.status" => data[:status]))
        span.finish(end_time: at)
      end

      def finish_turn(meta, data, status)
        turn = @turns.delete(meta[:task_id]) or return
        at = ts(meta[:at])
        set_usage(turn.span, data[:usage])
        turn.span.set_attribute("harness.status", status.to_s)
        turn.span.record_error(data[:message].to_s) if status == :error
        turn.tools.each { |s| s.finish(end_time: at) } # orphaned tool spans (failure mid-way)
        turn.span.finish(end_time: at)
      end

      def set_usage(span, usage)
        return unless usage

        span.set_attribute("harness.tokens.input", usage[:input_tokens]) if usage[:input_tokens]
        span.set_attribute("harness.tokens.output", usage[:output_tokens]) if usage[:output_tokens]
        span.set_attribute("harness.tokens.total", usage[:total_tokens]) if usage[:total_tokens]
        span.set_attribute("harness.tokens.cached", usage[:cached_tokens]) if usage[:cached_tokens]
        span.set_attribute("harness.model", usage[:model].to_s) if usage[:model]
      end

      def evict_oldest
        _id, turn = @turns.shift
        return unless turn

        turn.tools.each { |s| s.finish(end_time: nil) }
        turn.span.set_attribute("harness.status", "abandoned")
        turn.span.finish(end_time: nil)
      end

      # OTEL doesn't accept an attribute with a nil value — drops the absent keys.
      def attrs(hash) = hash.reject { |_, v| v.nil? }

      # ISO8601 (meta.at) -> Time; nil-safe (the span uses "now" when nil).
      def ts(at)
        return nil if at.nil? || at.to_s.empty?

        Time.parse(at.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end

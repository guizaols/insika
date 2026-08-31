# frozen_string_literal: true

require "time"

module Insika
  module Telemetry
    # Translates the insika Event Stream into OTEL SPANS and METRICS — the
    # already-existing observability spine becomes telemetry without touching the
    # core (Events observe; Telemetry only consumes).
    #
    # SPANS: one per TURN (insika.turn) with child spans per tool (insika.tool /
    # insika.data_tool), correlated by task_id. Latency is the span duration; the
    # agent/tenant/model/tokens/cost ride as ATTRIBUTES.
    #
    # METRICS: the SAME events also feed counters and histograms, so
    # volume/latency/tokens/cost are chartable WITHOUT span aggregation (which not
    # every backend does, and none does cheaply at retention). Metric attributes are
    # a deliberate LOW-CARDINALITY subset of the span attributes — never task_id or
    # session_id. `meter:` nil -> spans only (the metrics SDK is optional).
    #
    # `pricing:` nil -> no cost attribute/metric. Cost is an ESTIMATE from an
    # operator-declared rates table (see Pricing) — the engine ships no prices.
    #
    # PURE/testable: talks to a DUCK-TYPED `tracer` (start_span/set_attribute/
    # record_error/finish) and `meter` (create_counter/create_histogram -> add/
    # record) — the real OTEL adapters are injected in Telemetry.setup, fakes in
    # tests. Does NOT reference OpenTelemetry:: (loads without the gem).
    #
    # Robust: `record` NEVER raises (telemetry doesn't bring down a turn). Timestamps
    # come from each event's `meta.at` (spans reconstructed with real time).
    class Recorder
      Turn = Struct.new(:span, :tools, :labels, :start) # tools = FIFO queue of open tools
      OpenTool = Struct.new(:span, :name, :start)

      # Ceiling of open turns: a kill -9 without a terminal event would leave the turn
      # hanging; when exceeded, the oldest is closed (defensive, bounded memory).
      MAX_OPEN = 1_000

      # The metric instruments of the convention, created once per Recorder. Names
      # and units are part of the documented contract (docs/OBSERVABILITY.md) —
      # renaming one breaks every dashboard built on it.
      class Instruments
        attr_reader :turns, :turn_duration, :tokens, :cost, :tool_calls, :tool_duration,
                    :cache_hit_rate, :loop_intervened

        def initialize(meter)
          @turns = meter.create_counter("insika.turns", unit: "{turn}",
                                                        description: "Turns completed, by outcome")
          @turn_duration = meter.create_histogram("insika.turn.duration", unit: "s",
                                                                         description: "Wall time of a turn")
          @tokens = meter.create_counter("insika.tokens", unit: "{token}",
                                                          description: "Tokens consumed, by type")
          @cost = meter.create_counter("insika.cost", unit: "{USD}",
                                                      description: "Estimated turn cost in USD")
          @tool_calls = meter.create_counter("insika.tool.calls", unit: "{call}",
                                                                  description: "Tool invocations")
          @tool_duration = meter.create_histogram("insika.tool.duration", unit: "s",
                                                                         description: "Wall time of a tool call")
          @cache_hit_rate = meter.create_histogram("insika.cache.hit_rate", unit: "%",
                                                                            description: "Prompt-cache hit rate of a turn (cached / billed prompt tokens)")
          @loop_intervened = meter.create_counter("insika.tool.loop_intervened", unit: "{intervention}",
                                                                                 description: "Loop-detector warnings delivered to the model")
        end
      end

      def initialize(tracer:, meter: nil, pricing: nil)
        @tracer = tracer
        @instruments = meter && Instruments.new(meter)
        @pricing = pricing
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
        when :tool_loop_intervened then count_loop(meta, data)
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
        at = ts(meta[:at])
        # The metric label base: agent/tenant/command only — the low-cardinality
        # dimensions a dashboard groups by. task_id/session_id stay on the span.
        labels = attrs("insika.agent" => data[:agent], "insika.tenant" => data[:tenant],
                       "insika.command" => data[:command]&.to_s)
        span = @tracer.start_span(
          "insika.turn", parent: nil, start_time: at,
          attributes: labels.merge(attrs("insika.task_id" => id, "insika.session_id" => meta[:session_id]))
        )
        @turns[id] = Turn.new(span, [], labels, at)
      end

      def start_tool(meta, data)
        turn = @turns[meta[:task_id]] or return
        at = ts(meta[:at])
        name = data[:name]&.to_s
        span = @tracer.start_span("insika.tool", parent: turn.span, start_time: at,
                                  attributes: attrs("insika.tool" => name))
        turn.tools << OpenTool.new(span, name, at)
      end

      # FIFO: the model calls a tool and receives the result before the next one, so
      # the result matches the first open tool span of the turn.
      def finish_tool(meta)
        turn = @turns[meta[:task_id]] or return
        tool = turn.tools.shift or return
        at = ts(meta[:at])
        tool.span.finish(end_time: at)
        count_tool(turn, tool.name, "tool", elapsed(tool.start, at))
      end

      # data-tool emits a single event (name + HTTP status) -> point span.
      def point_tool(meta, data)
        turn = @turns[meta[:task_id]] or return
        at = ts(meta[:at])
        name = data[:tool]&.to_s
        span = @tracer.start_span("insika.data_tool", parent: turn.span, start_time: at,
                                  attributes: attrs("insika.tool" => name,
                                                    "insika.http.status" => data[:status]))
        span.finish(end_time: at)
        count_tool(turn, name, "data_tool", nil, "insika.http.status" => data[:status])
      end

      def finish_turn(meta, data, status)
        turn = @turns.delete(meta[:task_id]) or return
        at = ts(meta[:at])
        usage = data[:usage]
        set_usage(turn.span, usage)
        turn.span.set_attribute("insika.status", status.to_s)
        turn.span.record_error(data[:message].to_s) if status == :error
        turn.tools.each { |t| t.span.finish(end_time: at) } # orphans (failure mid-way)
        turn.span.finish(end_time: at)
        count_turn(turn, usage, status.to_s, elapsed(turn.start, at))
      end

      def set_usage(span, usage)
        return unless usage

        span.set_attribute("insika.tokens.input", usage[:input_tokens]) if usage[:input_tokens]
        span.set_attribute("insika.tokens.output", usage[:output_tokens]) if usage[:output_tokens]
        span.set_attribute("insika.tokens.total", usage[:total_tokens]) if usage[:total_tokens]
        span.set_attribute("insika.tokens.cached", usage[:cached_tokens]) if usage[:cached_tokens]
        span.set_attribute("insika.tokens.cache_creation", usage[:cache_creation_tokens]) if usage[:cache_creation_tokens]
        span.set_attribute("insika.model", usage[:model].to_s) if usage[:model]
        span.set_attribute("insika.model_source", usage[:model_source].to_s) if usage[:model_source]
        cost = estimated_cost(usage)
        span.set_attribute("insika.cost.usd", cost) if cost
      end

      # --- metrics (no-op when no meter was injected) ------------------------

      def count_turn(turn, usage, status, seconds)
        return unless @instruments

        model = usage && usage[:model]
        labels = turn.labels.merge(attrs("insika.status" => status, "insika.model" => model&.to_s))
        @instruments.turns.add(1, attributes: labels)
        @instruments.turn_duration.record(seconds, attributes: labels) if seconds
        count_usage(turn, usage)
        count_cache_hit(turn, usage)
      end

      # Same arithmetic as the Executor's per-agent series (stamp_cache_hit):
      # the billed prompt is fresh input + cache reads + cache writes, and the
      # hit rate is reads over the whole billed prompt — always in [0,100]. A
      # turn with no billed prompt tokens (no usage, usage without the fields)
      # records nothing: absence is not a 0% hit.
      def count_cache_hit(turn, usage)
        return unless usage

        billed = usage[:input_tokens].to_i + usage[:cached_tokens].to_i +
                 usage[:cache_creation_tokens].to_i
        return unless billed.positive?

        rate = (usage[:cached_tokens].to_i * 100.0) / billed
        base = turn.labels.merge(attrs("insika.model" => usage[:model]&.to_s))
        @instruments.cache_hit_rate.record(rate, attributes: base)
      end

      # The loop detector delivered its one-shot warning (`:tool_loop_intervened`,
      # counts and the tool name, never arguments). An orphan event (no open turn)
      # is ignored, like every other consumer of this stream.
      def count_loop(meta, data)
        return unless @instruments

        turn = @turns[meta[:task_id]] or return
        labels = turn.labels.merge(attrs("insika.tool" => data[:name]&.to_s))
        @instruments.loop_intervened.add(1, attributes: labels)
      end

      # Tokens ride ONE counter split by `insika.token.type` (instead of four
      # instruments) so a dashboard sums or splits them with the same query.
      def count_usage(turn, usage)
        return unless usage

        base = turn.labels.merge(attrs("insika.model" => usage[:model]&.to_s))
        { "input" => usage[:input_tokens], "output" => usage[:output_tokens],
          "cached" => usage[:cached_tokens], "cache_creation" => usage[:cache_creation_tokens] }.each do |type, n|
          @instruments.tokens.add(n.to_i, attributes: base.merge("insika.token.type" => type)) if n
        end
        cost = estimated_cost(usage)
        @instruments.cost.add(cost, attributes: base) if cost
      end

      def count_tool(turn, name, kind, seconds, extra = {})
        return unless @instruments

        labels = turn.labels.merge(attrs({ "insika.tool" => name, "insika.tool.kind" => kind }.merge(extra)))
        @instruments.tool_calls.add(1, attributes: labels)
        @instruments.tool_duration.record(seconds, attributes: labels) if seconds
      end

      def estimated_cost(usage) = @pricing&.cost(usage)

      # -----------------------------------------------------------------------

      def evict_oldest
        _id, turn = @turns.shift
        return unless turn

        turn.tools.each { |t| t.span.finish(end_time: nil) }
        turn.span.set_attribute("insika.status", "abandoned")
        turn.span.finish(end_time: nil)
        count_turn(turn, nil, "abandoned", nil)
      end

      # OTEL doesn't accept an attribute with a nil value — drops the absent keys.
      def attrs(hash) = hash.reject { |_, v| v.nil? }

      # Seconds between two reconstructed timestamps; nil when either is unknown
      # (a histogram must not record a made-up duration).
      def elapsed(from, to)
        return nil if from.nil? || to.nil?

        [to - from, 0.0].max.to_f
      end

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

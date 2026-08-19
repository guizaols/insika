# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # C7 — turn complete shadow pairs into judged pairs, using the judges the
    # operator ALREADY configured (settings["evals"], through JudgePanel — the
    # one builder the eval CLI and the refinement gate use too). Never automatic:
    # a Studio button or the CLI dispatches it, and it states its cost
    # (2 provider calls per judge per pair, both orders —   position-bias
    # rule) before it runs.
    #
    # Refusals are visible, a fake judge is not: no configured judges, or fewer
    # models than the criterion demands, is a ValidationError — an unjudged
    # window reads :invalid, where a window judged by judges nobody chose reads
    # as evidence.
    class JudgeShadowPairs
      DEFAULT_LIMIT = 50
      DEFAULT_EXPIRE_HOURS = 24

      def initialize(shadow_pairs:, settings_store:, criterion:, llm: nil, event_stream: nil)
        @shadow_pairs = shadow_pairs
        @settings_store = settings_store
        @criterion = criterion
        @llm = llm
        @event_stream = event_stream
      end

      # payload: { limit: Integer = 50, agent: String|nil, expire_after_hours: Integer|nil }
      # -> { judged:, skipped:, expired:, failed:, models: [..] }
      def call(command)
        payload = command.payload
        limit = begin
          Integer(payload[:limit] || payload["limit"] || DEFAULT_LIMIT)
        rescue ArgumentError
          raise ValidationError, "limit must be an integer"
        end
        agent = Coercion.presence(payload[:agent] || payload["agent"])
        expire_hours = begin
          Integer(payload[:expire_after_hours] || payload["expire_after_hours"] || DEFAULT_EXPIRE_HOURS)
        rescue ArgumentError
          raise ValidationError, "expire_after_hours must be an integer"
        end

        # Judges BEFORE the expire: a refusal (no judges, too few models) must
        # leave every pair untouched — expiring first would stamp :incomplete on
        # pairs and that is terminal evidence against a click that judged nothing.
        panel = Insika::Evals::JudgePanel.pairwise(settings, llm: @llm)
        raise ValidationError, "no judges configured in settings['evals'] — refusing to judge without judges" if panel.nil?

        pairwise, models = panel
        minimum = @criterion.rule.min_judge_models
        distinct = models.uniq
        if distinct.length < minimum
          raise ValidationError, "the criterion requires at least #{minimum} distinct judge models; " \
                                 "#{distinct.length} configured (#{distinct.join(', ')})"
        end

        # A mirror that dropped a half stops looking like pending work.
        expired = @shadow_pairs.expire(older_than: Time.now.utc - (expire_hours * 3600))

        judged = 0
        failed = 0
        @shadow_pairs.unjudged(limit: limit, agent: agent).each do |pair|
          if judge_pair(pair, pairwise, models)
            judged += 1
          else
            failed += 1
          end
        end
        skipped = @shadow_pairs.unjudged(agent: agent).length

        emit_summary(judged: judged, skipped: skipped, expired: expired, failed: failed, models: models)
        { judged: judged, skipped: skipped, expired: expired, failed: failed, models: models }
      end

      private

      def settings
        (@settings_store.get || {})["evals"] || {}
      end

      # -> true when the pair was judged. A raising judge leaves the pair
      # :complete (retryable on the next press) and never aborts the batch; an
      # empty side is recorded :unknown — visible, never a preference. The rescue
      # is broad on purpose: a provider outage raises the transport's own error
      # class (RubyLLM::Error, an HTTP status as StandardError), NOT an
      # Insika::Error — and one broken provider must not sink the rest of the
      # batch against this method's own contract.
      def judge_pair(pair, pairwise, models)
        verdict = pairwise.compare_texts(
          ours: Insika::Parity.transcript(pair.inbound, pair.insika_reply),
          theirs: Insika::Parity.transcript(pair.inbound, pair.incumbent_reply)
        )
        verdict ||= Insika::Evals::Pairwise::Verdict.new(
          outcome: "unknown", reason: "a side of the pair was empty", vs: "agent",
          judges: [], order_dependent: false
        )
        blob = verdict.to_h.merge("judged_at" => Time.now.utc.iso8601, "models" => models)
        @shadow_pairs.record_verdict(pair.id, verdict: blob)
        @event_stream&.emit(Insika::Event.new(
                              type: :shadow_judged,
                              data: { pair_id: pair.id, agent: pair.agent, outcome: blob[:outcome] },
                              meta: { at: Time.now.utc.iso8601 }
                            ))
        true
      rescue StandardError
        false
      end

      def emit_summary(judged:, skipped:, expired:, failed:, models:)
        return unless @event_stream

        @event_stream.emit(Insika::Event.new(
                             type: :shadow_judge_batch,
                             data: { judged: judged, skipped: skipped, expired: expired,
                                     failed: failed, models: models },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end

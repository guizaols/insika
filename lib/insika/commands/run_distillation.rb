# frozen_string_literal: true

module Insika
  module Commands
    # RFC-0034 C4: the ONLY path that writes proposals. Distills ONE session
    # end to end: read the transcript and the memory baseline, ask the model,
    # schema-drop, dedup against the ledger, write proposals, mark the session
    # distilled. Synchronous (it runs on the engine's worker fiber, C5) — it
    # creates no task and no turn (D2: no TaskStore work unit — a crash
    # mid-pass leaves the marker unwritten and the next pass re-scans; a
    # duplicate proposal is filtered by the ledger, never applied).
    class RunDistillation
      DEFAULT_IDLE_HOURS = 6
      DEFAULT_MIN_MESSAGES = 3
      DEFAULT_MAX_PROPOSALS = 10

      def initialize(profiles:, proposal_store:, session_store:, memory_store:,
                     settings_store:, event_stream:, distiller_factory: nil)
        @profiles = profiles
        @proposal_store = proposal_store
        @session_store = session_store
        @memory_store = memory_store
        @settings_store = settings_store
        @event_stream = event_stream
        @distiller_factory = distiller_factory ||
                             ->(config) { Distill::DistillerFactory.build(config, utility_model: utility_model) }
      end

      # payload: { session_id: } (agent resolved from the session, D6-bis)
      # -> { distilled: true, proposals: N, dropped: {...}, deduped: N, cost: {...} | nil }
      #  | { distilled: false, skipped: "already|untagged|no_agent|disabled|
      #        too_fresh|too_short|no_model" }
      def call(command)
        session_id = Coercion.presence(command.payload[:session_id] || command.payload["session_id"])
        raise ValidationError, "session_id is required" if session_id.nil?

        session = @session_store.find(session_id)
        raise Insika::NotFoundError, "session not found: #{session_id}" if session.nil?

        return skip("already") if @proposal_store.distilled?(session_id)

        customer = Coercion.presence(session.vars["customer"])
        return skip("untagged") if customer.nil?

        agent_id = Coercion.presence(session.vars["agent"])
        return skip("no_agent") if agent_id.nil?

        profile = @profiles[agent_id]
        return skip("no_agent") if profile.nil?

        config = Coercion.deep_stringify(profile.distill)
        return skip("disabled") if config.nil? || !Coercion.truthy?(config["enabled"])

        # D4: the pack's own idle threshold wins over the scan's lower bound —
        # a pack that wants 12 h is never distilled at 6.
        idle_hours = config["idle_hours"].to_i
        idle_hours = DEFAULT_IDLE_HOURS unless idle_hours.positive?
        return skip("too_fresh") unless idle?(session.updated_at, idle_hours)

        min_messages = config["min_messages"].to_i
        min_messages = DEFAULT_MIN_MESSAGES unless min_messages.positive?
        return skip("too_short") if session.messages.size < min_messages

        tenant = tenant_of(session_id)
        distiller = @distiller_factory.call(config)
        return skip("no_model") if distiller.nil?

        baseline = memory_baseline(tenant, customer)
        prompt = build_prompt(config, session, baseline)
        result = distiller.distill(prompt: prompt, message_count: session.messages.size,
                                   max_proposals: (config["max_proposals"] || DEFAULT_MAX_PROPOSALS).to_i)

        deduped = 0
        survivors = result[:proposals].reject do |proposal|
          dedup = deduped?(tenant, customer, proposal, baseline)
          deduped += 1 if dedup
          dedup
        end

        survivors.each do |proposal|
          expected = baseline[proposal["name"]]
          @proposal_store.create(
            tenant: tenant, customer: customer, session_ref: session_id,
            key: proposal["name"], value: proposal["value"],
            confidence: proposal["confidence"], evidence: proposal["turns"],
            expected_revision: expected && expected.updated_at,
            expected_existed: !expected.nil?
          )
        end

        @proposal_store.mark_distilled(session_id, agent: agent_id,
                                       proposals: survivors.size,
                                       dropped: result[:dropped],
                                       deduped: deduped,
                                       cost: result[:cost])
        @event_stream.emit(Insika::Event.new(
                             type: :distillation_completed,
                             # counts and ids only (D7) — a fact value never
                             # enters the stream.
                             data: { session_ref: session_id, agent: agent_id,
                                     proposals: survivors.size,
                                     dropped: result[:dropped],
                                     deduped: deduped,
                                     cost: result[:cost] },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { distilled: true, proposals: survivors.size, dropped: result[:dropped],
          deduped: deduped, cost: result[:cost] }
      end

      private

      # nil tenant in single-tenant deployments; the "<tenant>:" prefix of the
      # session id otherwise (D1 — the same reading ForgetCustomer uses).
      def tenant_of(session_id)
        tenant, rest = session_id.to_s.split(":", 2)
        rest.nil? ? nil : tenant
      end

      def skip(reason)
        { distilled: false, skipped: reason }
      end

      def idle?(updated_at, idle_hours)
        return false if Coercion.blank?(updated_at)

        Time.iso8601(updated_at.to_s) <= Time.now.utc - idle_hours * 3600
      rescue ArgumentError
        false
      end

      # Per fact key: the existence + updated_at at distill time (D5 — the CAS
      # baseline the approval compares against). Sorted by key for a stable
      # prompt.
      def memory_baseline(tenant, customer)
        @memory_store.facts(tenant: tenant, customer: customer)
                     .each_with_object({}) { |f, acc| acc[f.key] = f }
      end

      def deduped?(tenant, customer, proposal, baseline)
        key = proposal["name"].to_s
        value = proposal["value"].to_s
        return true if @proposal_store.decided?(tenant: tenant, customer: customer,
                                                key: key, value: value)
        return true if @proposal_store.open_pending?(tenant: tenant, customer: customer, key: key)

        applied = baseline[key]
        !applied.nil? && applied.value == value && applied.origin.to_s.start_with?("distilled:")
      end

      # The prompt gets the transcript slice (masked through the RFC-0009
      # output filter first — the RFC-0012 §3.4 redaction rule), the
      # customer's CURRENT facts (so the model can avoid re-proposing applied
      # facts), and the answer rules (the pack prompt or DEFAULT_PROMPT).
      def build_prompt(config, session, baseline)
        base = Coercion.presence(config["prompt"]) || Distill::DEFAULT_PROMPT
        transcript = render_transcript(session.messages)
        facts = baseline.values.map { |f| "- #{f.key}: #{f.value}" }
        <<~PROMPT
          #{base.rstrip}

          ## The conversation

          #{transcript}

          ## Facts already in this customer's memory (do not re-propose them)

          #{facts.empty? ? "(none)" : facts.join("\n")}
        PROMPT
      end

      def render_transcript(messages)
        redacted, = Insika::Safety::Detectors.redact(
          messages.each_with_index.map { |m, i| "[#{i}] #{m['role']}: #{m['content']}" }.join("\n")
        )
        redacted
      end

      def utility_model
        return nil unless @settings_store

        @settings_store.get["utility_model"]
      end
    end
  end
end

# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Read path for the session briefing: the per-session
      # working-state the agent keeps and asks for. Thin adapter over the
      # SessionStore, same pattern as Memory, deterministic. The MISSING list is
      # rendered, never implied — that list is what stops the model re-asking
      # for a field already given.
      #
      # TWO fragments, and the split is the whole point:
      #   · `<briefing>` (:system) — the DURABLE facts, what is already known.
      #     Head of the prompt, where reference material belongs.
      #   · `<recitation>` (:tail) — what is still missing and what the next step
      #     is, rendered AFTER the whole history, as the last thing before the
      #     current user message.
      # Attention is strongest at the END of the context: a goal stated only in
      # the head is the first thing a 30-call turn forgets. The recitation lives
      # in exactly one place — it was MOVED out of the head, never duplicated, so
      # a turn pays for it once.
      class Briefing < ContextProvider
        def initialize(session_store:)
          @session_store = session_store
        end

        # Stable id -> the context-trace category "briefing".
        def id = "briefing"

        # Pack-declared: no briefing_fields -> no provider (the Builder still
        # applies the `context_providers` allowlist on top — two gates, like Memory).
        def enabled_for?(profile)
          fields = profile.respond_to?(:briefing_fields) ? profile.briefing_fields : nil
          !Array(fields).empty?
        end

        # required? == false (default): a store failure degrades via the Builder's
        # warning path, never aborts the turn.
        def call(request)
          session = request.respond_to?(:session) ? request.session : nil
          return [] if session.nil? # one-shot turns have no briefing

          briefing = briefing_for(session)
          fields = briefing["fields"] || {}
          declared = Array(request.profile.briefing_fields)
          return [] if declared.empty? # defensive; enabled_for? already gates

          missing = declared.reject { |name| Coercion.present?(fields[name]) }
          next_step = briefing["next_step"]

          [head_fragment(declared, fields), tail_fragment(missing, next_step)].compact
        end

        private

        # Re-reads the briefing from the store, like the Session provider: the
        # persisted record is the source of truth, not the request's turn-start
        # snapshot. A read failure propagates to the Builder, which degrades it
        # to a :provider_warning (required? == false).
        def briefing_for(session)
          @session_store.find(session.id)&.briefing || {}
        end

        # The HEAD block — durable facts only. Byte contract:
        #   <briefing>
        #   known:
        #     size: M
        #   </briefing>
        # Nothing known yet -> no fragment at all (an empty `known:` header
        # teaches the model nothing and still costs a cache invalidation).
        # Stored keys NOT in the declaration are never rendered (they stay in the
        # store and reappear if the pack re-declares them).
        def head_fragment(declared, fields)
          known = declared.filter_map do |name|
            "  #{name}: #{flatten(fields[name])}" if Coercion.present?(fields[name])
          end
          return nil if known.empty?

          block = <<~BLOCK.strip
            <briefing>
            known:
            #{known.join("\n")}
            </briefing>
          BLOCK
          ContextFragment.build(content: block, placement: :system,
                                priority: Context::Priority::BRIEFING, source: id)
        end

        # The TAIL recitation — two lines, no more. Byte contract:
        #   <recitation>
        #   still missing: delivery_day
        #   next step: send the payment link tomorrow at 10
        #   </recitation>
        # `still missing` renders every declared field with no stored value
        # (including the all-missing case — that is this block's job); `next step`
        # renders only when non-nil. Neither -> no fragment.
        #
        # A `user` message, like every other engine append inside a turn
        # (LoopDetector, TurnBudget): the system prefix stays byte-stable, so the
        # cache breakpoint at its end keeps hitting.
        def tail_fragment(missing, next_step)
          lines = []
          lines << "still missing: #{missing.join(', ')}" unless missing.empty?
          lines << "next step: #{flatten(next_step)}" if Coercion.present?(next_step)
          return nil if lines.empty?

          block = <<~BLOCK.strip
            <recitation>
            #{lines.join("\n")}
            </recitation>
          BLOCK
          ContextFragment.build(content: { role: :user, content: block },
                                placement: :tail,
                                priority: Context::Priority::RECITATION, source: id)
        end

        # utf8 the value and flatten newlines/whitespace so a value can never
        # break the block's line structure.
        def flatten(value)
          Coercion.utf8(value.to_s).gsub(/\s+/, " ").strip
        end
      end
    end
  end
end
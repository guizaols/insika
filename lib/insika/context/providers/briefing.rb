# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Read path for the session briefing (RFC-0028): the per-session
      # working-state the agent keeps and asks for. Thin adapter over the
      # SessionStore, same pattern as Memory: one `:system` fragment,
      # deterministic. The MISSING list is rendered, never implied — that list
      # is what stops the model re-asking for a field already given.
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

          briefing = session.briefing || {}
          fields = briefing["fields"] || {}
          declared = Array(request.profile.briefing_fields)
          return [] if declared.empty? # defensive; enabled_for? already gates

          block = format_block(declared, fields, briefing["next_step"])
          return [] if block.nil?

          [ContextFragment.build(content: block, placement: :system,
                                 priority: Context::Priority::BRIEFING,
                                 source: id)]
        end

        private

        # Byte contract (the specs assert this shape):
        #   <briefing>
        #   known:
        #     size: M
        #   still missing: delivery_day
        #   next step: send the payment link tomorrow at 10
        #   </briefing>
        # Rules: `known` renders only when at least one declared field has a
        # stored value; `still missing` renders every declared field with no
        # stored value (including the all-missing case — that is the block's
        # job); `next step` renders only when non-nil; stored keys NOT in the
        # declaration are never rendered (they stay in the store and reappear if
        # the pack re-declares them).
        def format_block(declared, fields, next_step)
          known = declared.filter_map do |name|
            "  #{name}: #{flatten(fields[name])}" if Coercion.present?(fields[name])
          end
          missing = declared.reject { |name| Coercion.present?(fields[name]) }

          lines = []
          lines << "known:" unless known.empty?
          lines.concat(known)
          lines << "still missing: #{missing.join(', ')}" unless missing.empty?
          lines << "next step: #{flatten(next_step)}" if Coercion.present?(next_step)
          return nil if lines.empty?

          <<~BLOCK.strip
            <briefing>
            #{lines.join("\n")}
            </briefing>
          BLOCK
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
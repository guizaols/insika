# frozen_string_literal: true

require "ruby_llm"
require_relative "agent_enum"

module Insika
  module Tools
    # Shared write-edge plumbing for the two briefing tools: the
    # session id always comes from the turn's task — never from the model's
    # arguments — and the :briefing_updated event carries task/session
    # correlation for the trace.
    module BriefingWrite
      private

      # The turn's session, from the task (turn_state.rb:7) — never the model's args.
      def session_id
        @state.respond_to?(:task) ? @state.task&.session_id : nil
      end

      def no_session_error = { error: "no session to brief" }

      def emit(kind, field, value)
        @event_stream&.emit(Insika::Event.new(
                              type: :briefing_updated,
                              data: { kind: kind, field: field, value: value },
                              meta: { task_id: @state.task&.id, session_id: @state.task&.session_id }
                            ))
      end
    end

    # Write edge of the session briefing: the agent records what it
    # learned in THIS conversation — the working state it is accountable for
    # (tool-written, never engine-inferred). System builtin (like remember):
    # `require "ruby_llm"` stays in THIS file, loaded lazily by the Executor in
    # create_chat. Wired only when the pack declared briefing_fields AND the
    # builder has a session_store (double gate, like remember). Never enveloped:
    # deterministic in-process writes.
    class UpdateBriefing < RubyLLM::Tool
      include BriefingWrite

      # The class-level text carries no field list, so it can never render the
      # empty "field must be one of: ." placeholder; the instance adds the
      # DECLARED names (D3) to the description AND as the `field` enum (the
      # model sees the valid set in the schema instead of inventing one —
      # the set is instance-built. Per-instance, like the subagent tools' dynamic schemas.
      BASE_DESCRIPTION = "Records a fact learned in this conversation into the session briefing. " \
                         "Call it as soon as the customer gives one of these, and when they correct one."

      description BASE_DESCRIPTION

      def self.description_for(fields)
        names = Array(fields).map(&:to_s)
        names.empty? ? BASE_DESCRIPTION : "#{BASE_DESCRIPTION} field must be one of: #{names.join(', ')}."
      end

      param :field, desc: "The briefing field name (one of the declared list)"
      param :value, desc: "The value learned. Blank clears the field."

      def name = "update_briefing"

      def initialize(session_store:, fields:, event_stream:, state:)
        @session_store = session_store
        @fields = Array(fields).map(&:to_s)
        @event_stream = event_stream
        @state = state
        super()
      end

      def description
        self.class.description_for(@fields)
      end

      # The declared names become the `field` enum in the schema the provider
      # sees — per-turn data, like the subagent allowlist (Tools::AgentEnum).
      def params_schema
        @field_enum_schema ||= Insika::Tools::AgentEnum.inject(super, @fields, path: %i[field])
      end

      # E2: an undeclared name returns an ENVELOPE error to the model and never
      # persists. A missing session is the same shape (the model can retry later).
      def execute(field:, value:)
        sid = session_id
        return no_session_error if sid.to_s.empty?
        unless @fields.include?(field.to_s)
          return { error: "unknown field '#{field}'; declared: #{@fields.join(', ')}" }
        end

        session = @session_store.update_briefing(sid, field: field.to_s, value: value.to_s)
        emit("field", field.to_s, value.to_s)
        { updated: field.to_s, briefing: session.briefing }
      rescue Insika::NotFoundError
        { error: "session not found" }
      end

      # The agreed next step: same engine-owned briefing object,
      # sibling writer. Blank clears to nil.
      class SetNextStep < RubyLLM::Tool
        include BriefingWrite

        description "Records the next step agreed with the customer " \
                    "(e.g. 'send the payment link tomorrow at 10'). Blank clears it."
        param :text, desc: "The agreed next step, in one sentence"

        def name = "set_next_step"

        def initialize(session_store:, event_stream:, state:)
          @session_store = session_store
          @event_stream = event_stream
          @state = state
          super()
        end

        def execute(text:)
          sid = session_id
          return no_session_error if sid.to_s.empty?

          session = @session_store.set_next_step(sid, text: text.to_s)
          emit("next_step", nil, text.to_s)
          { next_step: session.briefing["next_step"] }
        rescue Insika::NotFoundError
          { error: "session not found" }
        end
      end
    end
  end
end
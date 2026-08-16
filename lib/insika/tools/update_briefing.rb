# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # Write edge of the session briefing (RFC-0028): the agent records what it
    # learned in THIS conversation — the working state it is accountable for
    # (tool-written, never engine-inferred). System builtin (like remember):
    # `require "ruby_llm"` stays in THIS file, loaded lazily by the Executor in
    # create_chat. Wired only when the pack declared briefing_fields AND the
    # builder has a session_store (double gate, like remember). Never enveloped:
    # deterministic in-process writes.
    class UpdateBriefing < RubyLLM::Tool
      # The description lists the DECLARED names (D3): the model sees the valid
      # set in the schema text instead of inventing one. Per-instance, like the
      # subagent tools' dynamic schemas.
      def self.description_for(fields)
        "Records a fact learned in this conversation into the session briefing. " \
          "field must be one of: #{fields.join(', ')}. Call it as soon as the " \
          "customer gives one of these, and when they correct one."
      end

      description description_for([]) # placeholder; the instance overrides
      param :field, desc: "The briefing field name (one of the declared list)"
      param :value, desc: "The value learned. Blank clears the field."

      def name = "update_briefing"

      def initialize(session_store:, fields:, event_stream:, state:)
        @session_store = session_store
        @fields = fields
        @event_stream = event_stream
        @state = state
        super()
      end

      def description
        self.class.description_for(@fields)
      end

      # E2: an undeclared name returns an ENVELOPE error to the model and never
      # persists. A missing session is the same shape (the model can retry later).
      def execute(field:, value:)
        sid = session_id
        return { error: "no session to brief" } if sid.to_s.empty?
        unless @fields.include?(field.to_s)
          return { error: "unknown field '#{field}'; declared: #{@fields.join(', ')}" }
        end

        session = @session_store.update_briefing(sid, field: field.to_s, value: value.to_s)
        emit("field", field.to_s, value.to_s)
        { updated: field.to_s, briefing: session.briefing }
      rescue Insika::NotFoundError
        { error: "session not found" }
      end

      # The agreed next step (RFC-0028 D4): same engine-owned briefing object,
      # sibling writer. Blank clears to nil.
      class SetNextStep < RubyLLM::Tool
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
          return { error: "no session to brief" } if sid.to_s.empty?

          session = @session_store.set_next_step(sid, text: text.to_s)
          emit("next_step", nil, text.to_s)
          { next_step: session.briefing["next_step"] }
        rescue Insika::NotFoundError
          { error: "session not found" }
        end

        private

        # The turn's session, from the task (turn_state.rb:7) — never the model's args.
        def session_id = @state.respond_to?(:task) ? @state.task&.session_id : nil

        def emit(kind, field, value)
          @event_stream&.emit(Insika::Event.new(
                                type: :briefing_updated,
                                data: { kind: kind, field: field, value: value },
                                meta: { task_id: @state.task&.id, session_id: @state.task&.session_id }
                              ))
        end
      end

      private

      # The turn's session, from the task (turn_state.rb:7) — never the model's args.
      def session_id = @state.respond_to?(:task) ? @state.task&.session_id : nil

      def emit(kind, field, value)
        @event_stream&.emit(Insika::Event.new(
                              type: :briefing_updated,
                              data: { kind: kind, field: field, value: value },
                              meta: { task_id: @state.task&.id, session_id: @state.task&.session_id }
                            ))
      end
    end
  end
end
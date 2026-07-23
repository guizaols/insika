# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # Write path of the cross-session memory: the agent stores a
    # fact (key+value, durable upsert) or a note (value without key) on demand.
    # Deterministic — NO model call.
    # System builtin (like load_skill/tool_search): `require "ruby_llm"` stays
    # in THIS file, loaded lazily by the Executor in create_chat.
    class Remember < RubyLLM::Tool
      description "Stores information to remember in future conversations. Use `key` " \
                  "for a durable key-value fact (overwrites the previous one); omit " \
                  "`key` for a free-form note."
      param :value, desc: "The content to remember"
      param :key, desc: "Fact key (e.g.: 'plan', 'name'); omit for a note", required: false

      # otherwise RubyLLM derives "insika--tools--remember" from the class name.
      def name = "remember"

      def initialize(store, tenant, event_stream:, state:)
        @store = store
        @tenant = tenant
        @event_stream = event_stream
        @state = state
        super()
      end

      def execute(value:, key: nil)
        if key.to_s.strip.empty?
          note = @store.add_note(tenant: @tenant, text: value.to_s)
          emit("note", note.id)
          { remembered: "note", id: note.id }
        else
          @store.put_fact(tenant: @tenant, key: key.to_s, value: value.to_s)
          emit("fact", key.to_s)
          { remembered: "fact", key: key.to_s }
        end
      end

      private

      def emit(kind, ref)
        @event_stream.emit(Insika::Event.new(
                             type: :memory_written,
                             data: { kind: kind, key: ref },
                             meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                           ))
      end
    end
  end
end

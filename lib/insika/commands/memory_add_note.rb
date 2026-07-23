# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: appends a free-form note
    # (append-only) to the agent's memory (MemoryStore, `notes` layer). Scoped
    # by `tenant`. Synchronous; does not create a Task. -> Note.
    class MemoryAddNote
      def initialize(memory_store:, event_stream:)
        @memory_store = memory_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        text = AgentPayload.presence(p[:text])
        raise Insika::ValidationError, "text is required" if text.nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        note = @memory_store.add_note(tenant: tenant, text: text)
        @event_stream.emit(Insika::Event.new(
                             type: :memory_note_added,
                             data: { tenant: tenant, note_id: note.id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        note
      end
    end
  end
end

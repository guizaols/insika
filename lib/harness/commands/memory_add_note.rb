# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: acrescenta uma nota livre
    # (append-only) na memória do agente (MemoryStore, camada `notes`). Escopado
    # por `tenant`. Síncrono; não cria Task. -> Note.
    class MemoryAddNote
      def initialize(memory_store:, event_stream:)
        @memory_store = memory_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        text = AgentPayload.presence(p[:text])
        raise Harness::ValidationError, "text é obrigatório" if text.nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        note = @memory_store.add_note(tenant: tenant, text: text)
        @event_stream.emit(Harness::Event.new(
                             type: :memory_note_added,
                             data: { tenant: tenant, note_id: note.id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        note
      end
    end
  end
end

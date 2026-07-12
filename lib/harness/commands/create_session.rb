# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: cria uma sessão e responde síncrono —
    # não cria Task. Payload `{ vars: {} }` -> retorna Session.
    class CreateSession
      # event_stream: qualquer objeto com #emit(event) (testes usam spy).
      def initialize(session_store:, event_stream:)
        @session_store = session_store
        @event_stream = event_stream
      end

      def call(command)
        # Aceita chave símbolo (dispatch interno) e string (JSON do transporte)
        # — normaliza na borda do handler.
        vars = command.payload[:vars] || command.payload["vars"] || {}
        raise Harness::ValidationError, "vars deve ser um Hash" unless vars.is_a?(Hash)

        session = @session_store.create(vars: vars)
        # :session_created é do catálogo fechado (origem: handler CreateSession).
        # meta sem task_id/seq (controle não tem Task); Event#to_h faz meta.compact.
        @event_stream.emit(Harness::Event.new(
                             type: :session_created,
                             data: { session_id: session.id },
                             meta: { session_id: session.id, at: Time.now.utc.iso8601 }
                           ))
        session
      end
    end
  end
end

# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa D / D6): faz merge de um patch nos
    # settings gerais (timeouts/streaming/compaction) e persiste no SettingsStore.
    # Só o que veio no patch muda; o resto (e os defaults) é preservado. Vale no
    # próximo turno que ler settings. -> Hash (settings resultante).
    class UpdateSettings
      def initialize(settings_store:, event_stream:)
        @settings_store = settings_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        patch = p[:patch]
        raise Harness::ValidationError, "patch deve ser um objeto" unless patch.nil? || patch.is_a?(Hash)
        raise Harness::ValidationError, "patch vazio" if patch.nil? || patch.empty?

        settings = @settings_store.update(patch)
        @event_stream.emit(Harness::Event.new(
                             type: :settings_updated,
                             data: { keys: patch.keys.map(&:to_s) },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        settings
      end
    end
  end
end

# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: merges a patch into the
    # general settings (timeouts/streaming/compaction) and persists it in the SettingsStore.
    # Only what came in the patch changes; the rest (and the defaults) is preserved. Takes effect on the
    # next turn that reads settings. -> Hash (resulting settings).
    class UpdateSettings
      def initialize(settings_store:, event_stream:)
        @settings_store = settings_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        patch = p[:patch]
        raise Harness::ValidationError, "patch must be an object" unless patch.nil? || patch.is_a?(Hash)
        raise Harness::ValidationError, "empty patch" if patch.nil? || patch.empty?

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

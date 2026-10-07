# frozen_string_literal: true

require "time"

module Insika
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
        raise Insika::ValidationError, "patch must be an object" unless patch.nil? || patch.is_a?(Hash)
        raise Insika::ValidationError, "empty patch" if patch.nil? || patch.empty?

        patch = patch.transform_keys(&:to_s)
        defaults = patch.delete("agent_defaults")
        settings = patch.empty? ? @settings_store.get : @settings_store.update(patch)
        if defaults
          settings = settings.merge("agent_defaults" => @settings_store.put_agent_defaults(agent_defaults!(defaults)))
          patch["agent_defaults"] = defaults
        end
        @event_stream.emit(Insika::Event.new(
                             type: :settings_updated,
                             data: { keys: patch.keys.map(&:to_s) },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        settings
      end

      private

      # agent_defaults replace per field (SettingsStore#put_agent_defaults), and
      # only the fields an agent can inherit (AgentDefaults::FIELDS).
      def agent_defaults!(defaults)
        raise Insika::ValidationError, "agent_defaults must be an object" unless defaults.is_a?(Hash)

        unknown = defaults.keys.map(&:to_s) - Insika::AgentDefaults::FIELDS
        raise Insika::ValidationError, "agent_defaults cannot set #{unknown.join(", ")}" unless unknown.empty?

        defaults
      end
    end
  end
end

# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: removes a kit. Agents that still list it simply stop
    # receiving its items (Kits.apply ignores unknown names). -> { name:, deleted: true }.
    class DeleteKit
      def initialize(settings_store:, event_stream:)
        @settings_store = settings_store
        @event_stream = event_stream
      end

      def call(command)
        name = AgentPayload.presence(AgentPayload.symbolize(command.payload)[:name]).to_s
        raise Insika::NotFoundError, "kit '#{name}' not found" unless @settings_store.kits.key?(name)

        @settings_store.put_kit(name, nil)
        @event_stream.emit(Insika::Event.new(type: :kit_deleted, data: { kit: name },
                                             meta: { at: Time.now.utc.iso8601 }))
        { name: name, deleted: true }
      end
    end
  end
end

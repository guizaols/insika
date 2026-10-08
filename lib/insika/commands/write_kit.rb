# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: creates or replaces one kit (Insika::Kits). Subscribers pick
    # it up on their next turn. -> Hash (the saved kit).
    class WriteKit
      def initialize(settings_store:, event_stream:)
        @settings_store = settings_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name]).to_s
        kit = { "description" => p[:description], "skills" => p[:skills],
                "tools" => p[:tools], "tool_groups" => p[:tool_groups] }
        saved = @settings_store.put_kit(name, kit)[name]
        @event_stream.emit(Insika::Event.new(type: :kit_written, data: { kit: name },
                                             meta: { at: Time.now.utc.iso8601 }))
        saved
      end
    end
  end
end

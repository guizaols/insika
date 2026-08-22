# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Studio/CLI-facing adapter over Insika::Demo::Seeder — the one path both
    # `insika demo:seed` and the Studio's "Seed demo data" button use (same
    # discipline as RunDistillation: one object, two front doors).
    class SeedDemoData
      def initialize(seeder:, event_stream:)
        @seeder = seeder
        @event_stream = event_stream
      end

      # payload: { force: bool } -> the seeder's result Hash.
      def call(command)
        force = Coercion.truthy?(command.payload[:force] || command.payload["force"])
        result = @seeder.seed!(force: force)
        if result[:seeded]
          @event_stream.emit(Insika::Event.new(
                               type: :demo_data_seeded,
                               data: { agent: result[:agent], counts: result[:counts] },
                               meta: { at: Time.now.utc.iso8601 }
                             ))
        end
        result
      end
    end
  end
end

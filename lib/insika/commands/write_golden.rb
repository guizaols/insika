# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: writes an eval case into the GoldenStore. This
    # is what lets a domain owner add a case — above all its RUBRIC, the part of an eval
    # that is plain language — without a checkout and a text editor.
    #
    # The payload carries the case as DATA (`case:`), the same mapping the YAML file
    # holds; the store validates it with the one loader, so a case authored here and a
    # case read from `evals/golden/` cannot diverge. -> { id, agent }.
    class WriteGolden
      def initialize(golden_store:, event_stream:)
        @goldens = golden_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        raise Insika::ValidationError, "case is required" unless p[:case].is_a?(Hash)

        golden = @goldens.write(p[:case])
        emit(:golden_written, id: golden.id, agent: golden.agent)
        { id: golden.id, agent: golden.agent }
      end

      private

      def emit(type, **data)
        @event_stream.emit(Insika::Event.new(type: type, data: data,
                                            meta: { at: Time.now.utc.iso8601 }))
      end
    end

    # Control command: removes an eval case. The corpus on disk is the way back
    # (`insika evals:import`), which is why this needs no version history.
    # -> { id, existed }.
    class DeleteGolden
      def initialize(golden_store:, event_stream:)
        @goldens = golden_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        id = AgentPayload.presence(p[:id])
        raise Insika::ValidationError, "id is required" if id.nil?

        existed = @goldens.delete(id)
        @event_stream.emit(Insika::Event.new(type: :golden_deleted, data: { id: id, existed: existed },
                                            meta: { at: Time.now.utc.iso8601 }))
        { id: id, existed: existed }
      end
    end
  end
end

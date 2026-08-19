# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # The Studio's delete on the Artifacts tab — a bus command, like every
    # Studio mutation (the Studio never writes a store directly). Idempotent:
    # an unknown id is a no-op, not an error.
    class DeleteArtifact
      def initialize(artifact_store:, event_stream:)
        @artifact_store = artifact_store
        @event_stream = event_stream
      end

      # -> { deleted: id } | { deleted: nil } (unknown id).
      def call(command)
        id = Coercion.presence(command.payload[:id] || command.payload["id"])
        raise ValidationError, "id is required" if id.nil?

        deleted = @artifact_store.delete(id.to_s)
        if deleted
          @event_stream.emit(Insika::Event.new(
                               type: :artifact_deleted,
                               data: { id: id.to_s },
                               meta: { at: Time.now.utc.iso8601 }
                             ))
          { deleted: id.to_s }
        else
          { deleted: nil }
        end
      end
    end
  end
end
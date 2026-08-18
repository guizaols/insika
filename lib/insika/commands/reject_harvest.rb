# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # RFC-0035 C10/C11 — the operator's dismissal: a candidate that is NOT yet
    # gated can be rejected by a human directly (a human may always outvote
    # the miner). The thin wrapper over `mark_rejected`.
    class RejectHarvest
      def initialize(harvest_store:, event_stream:)
        @harvest_store = harvest_store
        @event_stream = event_stream
      end

      # payload: { candidate_id:, operator?, note? }
      # -> Candidate (rejected)
      def call(command)
        p = AgentPayload.symbolize(command.payload)
        candidate_id = AgentPayload.presence(p[:candidate_id])
        raise Insika::ValidationError, "candidate_id is required" if candidate_id.nil?

        candidate = @harvest_store.find_candidate(candidate_id) ||
                    (raise Insika::NotFoundError, "harvest candidate not found: #{candidate_id}")
        operator = (AgentPayload.presence(p[:operator]) || command.meta[:operator] || "operator").to_s
        rejected = @harvest_store.mark_rejected(candidate.id, operator: operator, note: p[:note])

        @event_stream.emit(Insika::Event.new(
                             type: :harvest_rejected,
                             data: { candidate_id: candidate.id, agent: candidate.agent,
                                     operator: operator },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        rejected
      end
    end
  end
end
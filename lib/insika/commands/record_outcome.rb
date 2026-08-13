# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command (WS7): the operator or the integration records a business
    # OUTCOME for a conversation — `{ outcome: "conversion", value: R$ }` — via
    # `POST /v1/outcomes`. The engine transports it and never interprets it; the
    # Studio's scorecard card aggregates the store. The record is tenant-stamped
    # (WS1): a tenant principal's outcomes land under its own tenant, invisible
    # to every other tenant and to nothing the tenant can read.
    class RecordOutcome
      def initialize(outcome_store:, event_stream:)
        @outcome_store = outcome_store
        @event_stream = event_stream
      end

      def call(command)
        payload = command.payload
        agent = Coercion.presence(payload[:agent] || payload["agent"])
        outcome = Coercion.presence(payload[:outcome] || payload["outcome"])
        raise ValidationError, "agent is required" if agent.nil?
        raise ValidationError, "outcome is required" if outcome.nil?

        value = payload[:value] || payload["value"]
        unless value.nil? || value.is_a?(Numeric)
          raise ValidationError, "value must be a number"
        end

        session_id = payload[:session_id] || payload["session_id"]
        record = @outcome_store.create(
          tenant: command.meta[:tenant], agent: agent, session_id: session_id,
          outcome: outcome, value: value
        )
        @event_stream.emit(Insika::Event.new(
                             type: :outcome_recorded,
                             data: { agent: agent, outcome: outcome, value: record.value,
                                     session_id: record.session_id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        record
      end
    end
  end
end
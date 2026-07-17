# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Every mutating interaction becomes a Command. Shared shape:
  #   type:    Symbol (:create_session, :send_message, :trigger_workflow,
  #                    :cancel_task, :resume_task)
  #   payload: Hash validated by the handler
  #   meta:    { command_id:, tenant:, transport:, issued_at: }
  #
  # `Command` does not validate payload (that's the handler's job) and does not
  # know about the bus.
  Command = Data.define(:type, :payload, :meta) do
    # Factory that fills in the meta defaults. `type` is
    # normalized to Symbol; a nil `payload` becomes {} (the handler decides
    # whether required fields are missing).
    def self.build(type, payload = {}, transport: :internal, tenant: nil)
      new(
        type: type.to_sym,
        payload: payload || {},
        meta: {
          command_id: SecureRandom.uuid,
          tenant: tenant,
          transport: transport,
          issued_at: Time.now.utc.iso8601
        }
      )
    end
  end
end

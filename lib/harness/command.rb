# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Toda interação de mutação vira Command. Tipo compartilhado:
  #   type:    Symbol (:create_session, :send_message, :trigger_workflow,
  #                    :cancel_task, :resume_task)
  #   payload: Hash validado pelo handler
  #   meta:    { command_id:, tenant:, transport:, issued_at: }
  #
  # `Command` não valida payload (isso é do handler) e não conhece o bus.
  Command = Data.define(:type, :payload, :meta) do
    # Factory que preenche os defaults de meta. `type` é
    # normalizado para Symbol; `payload` nil vira {} (o handler decide se
    # campos obrigatórios faltam).
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

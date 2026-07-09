# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Toda interação de mutação vira Command (00-overview §2, RFC-0001 princípio 5;
  # doc 03). Tipo compartilhado:
  #   type:    Symbol (:create_session, :send_message, :trigger_workflow,
  #                    :cancel_task, :resume_task)
  #   payload: Hash validado pelo handler (schemas no doc 03 §3)
  #   meta:    { command_id:, tenant:, transport:, issued_at: }
  #
  # Tipo compartilhado do overview §2 — introduzido na task 08 (o Recovery
  # despacha :resume_task) e estendido aqui (task 09) com o factory `build`.
  # `Command` não valida payload (isso é do handler) e não conhece o bus.
  Command = Data.define(:type, :payload, :meta) do
    # Factory que preenche os defaults de meta (doc 03 §2). `type` é
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

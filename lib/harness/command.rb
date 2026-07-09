# frozen_string_literal: true

module Harness
  # Toda interação de mutação vira Command (00-overview §2, RFC-0001 princípio 5;
  # doc 03). Tipo compartilhado:
  #   type:    Symbol (:create_session, :send_message, :trigger_workflow,
  #                    :cancel_task, :resume_task)
  #   payload: Hash validado pelo handler (schemas no doc 03)
  #   meta:    { command_id:, tenant:, transport:, issued_at: }
  #
  # Tipo compartilhado do overview §2 — deveria ter vindo na task 01 junto dos
  # demais tipos base, mas não foi criado lá; introduzido aqui (task 08) porque
  # o Recovery despacha um Command :resume_task. O CommandBus + handlers são a
  # task 09, que constrói sobre este tipo. Definição idêntica ao overview §2.
  Command = Data.define(:type, :payload, :meta)
end

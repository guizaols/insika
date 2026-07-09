# frozen_string_literal: true

module Harness
  # Snapshot por turno (00-overview §2, doc 02 §3, RFC-0006 §5). O checkpoint do
  # turno n contém o estado NO INÍCIO do turno n — retomar = reexecutar o turno
  # n inteiro. `messages` é o transcript MATERIALIZADO (não um cursor, L3): o
  # checkpoint é autossuficiente e a retomada não depende do Session Store.
  #
  # `completed_side_effects`: ids de tool calls não-idempotentes já concluídas
  # dentro do turno (a retomada as responde com "already_executed", L5).
  #
  # Tipo compartilhado do overview §2 — deveria ter vindo na task 01 junto dos
  # demais tipos base, mas não foi criado lá; introduzido aqui (task 07) porque
  # é a entrada/saída do CheckpointStore. Definição idêntica ao overview §2.
  Checkpoint = Data.define(:task_id, :turn, :session_id, :agent_id,
                           :messages, :completed_side_effects, :created_at)
end

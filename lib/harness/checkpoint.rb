# frozen_string_literal: true

module Harness
  # Snapshot por turno. O checkpoint do
  # turno n contém o estado NO INÍCIO do turno n — retomar = reexecutar o turno
  # n inteiro. `messages` é o transcript MATERIALIZADO (não um cursor): o
  # checkpoint é autossuficiente e a retomada não depende do Session Store.
  #
  # `completed_side_effects`: ids de tool calls não-idempotentes já concluídas
  # dentro do turno (a retomada as responde com "already_executed").
  Checkpoint = Data.define(:task_id, :turn, :session_id, :agent_id,
                           :messages, :completed_side_effects, :created_at)
end

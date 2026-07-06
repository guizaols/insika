# frozen_string_literal: true

module Harness
  # Tudo que o runtime emite é um Event (catálogo canônico fechado em
  # 00-overview D5 — novos tipos exigem atualizar aquela tabela).
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotônico por task).
  # :done e :error são mantidos pelo contrato com o consumidor da Fase 0;
  # :task_completed/:task_failed são os equivalentes com correlação.
  Event = Data.define(:type, :data, :meta) do
    def initialize(type:, data:, meta: {})
      super
    end

    def to_h = { type:, **data, meta: meta.compact }
  end
end

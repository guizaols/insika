# frozen_string_literal: true

module Harness
  # Unidade de contexto produzida por um provider.
  # Tipo COMPARTILHADO (Harness::, não Harness::Context::).
  #   placement: :system | :history | :tool_context
  #   priority:  Integer; maior = mais importante (sobrevive a cortes)
  #   tokens:    Integer | nil; estimado pelo Builder quando nil
  #   source:    String — id do provider (auditoria)
  #   pinned:    true -> incortável no orçamento (ex.: identidade)
  ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                                :source, :pinned) do
    def self.build(content:, placement:, source:, priority: 50, tokens: nil,
                   pinned: false)
      new(content: content, placement: placement, priority: priority,
          tokens: tokens, source: source, pinned: pinned)
    end
  end
end

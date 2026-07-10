# frozen_string_literal: true

module Harness
  # Hooks ALTERAM a entrada/saída de UM estágio que envolvem (princípio
  # constitucional 9, doc 05 §1): Middleware modifica, Hooks alteram, Events
  # observam. Não criam fluxo próprio nem pulam estágios. Síncronos (doc 05 §5)
  # e sem rescue (doc 05 §6) — o mapeamento erro->estado é do Executor.
  class Hooks
    PAIRS = %i[task prompt agent tool].freeze # RFC-0002 §6

    def initialize
      @before = Hash.new { |h, k| h[k] = [] }
      @after = Hash.new { |h, k| h[k] = [] }
    end

    # callables; múltiplos por par. A ordem de registro é significativa.
    def register(pair, before: nil, after: nil)
      raise ArgumentError, "par de hook desconhecido: #{pair.inspect}" unless PAIRS.include?(pair)

      @before[pair] << before if before
      @after[pair] << after if after
      nil
    end

    # befores na ordem de registro (podem ALTERAR o subject retornando o novo),
    # yield(subject), afters na ordem INVERSA (podem alterar o resultado). Sem
    # registros -> degenera em yield(subject) (no-op). Hook que não altera
    # devolve o que recebeu; devolver nil É alterar para nil (sem caso especial).
    def around(pair, subject)
      raise ArgumentError, "par de hook desconhecido: #{pair.inspect}" unless PAIRS.include?(pair)

      @before[pair].each { |hook| subject = hook.call(subject) }
      result = yield(subject)
      @after[pair].reverse_each { |hook| result = hook.call(result) }
      result
    end
  end
end

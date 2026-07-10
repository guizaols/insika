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
      run_after(pair, yield(run_before(pair, subject)))
    end

    # Metades públicas do around (task 19). Necessárias para o par :tool, cujo
    # "corpo" do estágio é o loop interno do RubyLLM (doc 03 §6) — não há bloco
    # a envolver; as metades são chamadas dos callbacks before_tool_call/
    # after_tool_result separadamente.
    def run_before(pair, subject)
      raise ArgumentError, "par de hook desconhecido: #{pair.inspect}" unless PAIRS.include?(pair)

      @before[pair].reduce(subject) { |subj, hook| hook.call(subj) }
    end

    def run_after(pair, result)
      raise ArgumentError, "par de hook desconhecido: #{pair.inspect}" unless PAIRS.include?(pair)

      @after[pair].reverse.reduce(result) { |res, hook| hook.call(res) }
    end
  end
end

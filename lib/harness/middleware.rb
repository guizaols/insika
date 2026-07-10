# frozen_string_literal: true

module Harness
  # Elo da cadeia (estágio 4, doc 05 §2). Middleware MODIFICA o TurnState,
  # curto-circuita e tem efeito operacional (rate limit, tracing, custo) — NÃO
  # decide permissão de tool/skill (isso é Policy, doc 05 L5). Curto-circuito =
  # NÃO chamar `nxt` e setar `state.halt_reason`. Setar halt_reason E chamar
  # nxt é violação de contrato (o Executor prioriza o halt_reason na volta).
  #
  # Concorrência (doc 05 §5): roda no fiber da task; IO (ex.: tracing exporter)
  # deve ser async fora do caminho (`Async { ... }` fire-and-forget) ou aceitar
  # a latência no turno. Sem timeout próprio (coberto pelo timeout do turno).
  class Middleware
    def call(state, &nxt)
      nxt.call(state) # elo default: pass-through
    end
  end

  # Composição rack-like: ordem de registro = ordem de execução (o primeiro é o
  # elo mais externo). NÃO faz rescue (exceção propaga como falha do turno, D4)
  # nem tem mecanismo especial de halt — o curto-circuito é estrutural (o elo
  # não chama nxt).
  class MiddlewareStack
    def initialize(middlewares = [])
      @middlewares = middlewares
    end

    def call(state, &terminal)
      chain = @middlewares.reverse.reduce(terminal) do |nxt, mw|
        proc { |s| mw.call(s, &nxt) }
      end
      chain.call(state)
    end
  end
end

# frozen_string_literal: true

module Harness
  # MUTÁVEL de propósito (única exceção aos Data):
  # o Middleware MODIFICA a execução — os elos escrevem nestes campos.
  class TurnState
    attr_reader :task, :profile, :turn # identidade do turno (1-based)
    attr_accessor :message,            # entrada (Middleware pode reescrever)
                  :context,            # ContextPackage do Builder
                  :allowed_tools,      # Resolution do Policy Engine
                  :allowed_skills,
                  :chat,               # instância RubyLLM::Chat do turno
                  :halt_reason         # setado por Middleware ao curto-circuitar

    # Interno (não faz parte do contrato): correlação tool_call
    # corrente <-> decorators de tool (side-effects/skip).
    attr_accessor :current_tool_call

    # Interno: impl_name(String) -> nome ESTÁVEL da capability que o
    # resolveu, calculado por resolve_capabilities ANTES do policy_request e
    # consultado DEPOIS de @policy_engine.decide, na junção pós-Policy, para
    # decidir quais impls entram como Capability::ResolvedTool. {} = sem
    # capability_registry ou profile.capabilities vazio (paridade).
    attr_accessor :capability_names

    # Interno (memória): tenant do turno (do Command), escopo do write path
    # (`remember` tool). Setado no run_pipeline; nil = DEFAULT_TENANT no MemoryStore.
    attr_accessor :tenant

    # Interno (Fase 6/D2/G4): contexto de turno depositado nas data-tools p/
    # resolver {{ctx.*}} (chat_id/agent_id/tenant/store_id) e emitir
    # X-Chat-Id/X-Store-Id/X-Agent-Id. Hash de símbolos, setado no run_pipeline.
    # Vem do TURNO, nunca dos args do modelo (R2). Distinto de `tenant` (memória).
    attr_accessor :turn_context

    # Interno (Tool Search): ids de side-effects já concluídos no turno
    # interrompido, propagados às tools PROMOVIDAS pelo tool_search (mesmo `skip`
    # que o wrap_tools das eager recebe). Setado no run_pipeline;
    # nil = turno novo (Array(nil) => []).
    attr_accessor :skip_side_effects

    # Gate de aprovação. `requires_approval` = nomes de tools que exigem
    # aprovação (Resolution); `approval_coordinator` = objeto (o Executor) que
    # cria o PendingAction/suspende/aguarda; `actor` = mailbox do turno (usada
    # pelo coordenador para await(:approval)).
    attr_accessor :requires_approval, :approval_coordinator, :actor

    def initialize(task:, profile:, turn:, message:)
      @task = task
      @profile = profile
      @turn = turn
      @message = message
      @capability_names = {}
    end
  end
end

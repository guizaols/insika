# frozen_string_literal: true

module Harness
  # MUTÁVEL de propósito (única exceção aos Data deste techspec, doc 03 L5):
  # o Middleware MODIFICA a execução — os elos escrevem nestes campos.
  class TurnState
    attr_reader :task, :profile, :turn # identidade do turno (1-based)
    attr_accessor :message,            # entrada (Middleware pode reescrever)
                  :context,            # ContextPackage do Builder (doc 04)
                  :allowed_tools,      # Resolution do Policy Engine (doc 05)
                  :allowed_skills,
                  :chat,               # instância RubyLLM::Chat do turno
                  :halt_reason         # setado por Middleware ao curto-circuitar

    # Interno (não faz parte do contrato do doc 03 §3): correlação tool_call
    # corrente <-> decorators de tool (side-effects/skip, task 13).
    attr_accessor :current_tool_call

    # Interno (P2B, D4): impl_name(String) -> nome ESTÁVEL da capability que o
    # resolveu, calculado por resolve_capabilities ANTES do policy_request e
    # consultado DEPOIS de @policy_engine.decide, na junção pós-Policy, para
    # decidir quais impls entram como Capability::ResolvedTool. {} = sem
    # capability_registry ou profile.capabilities vazio (paridade Fase 1).
    attr_accessor :capability_names

    # Interno (P2C, memória): tenant do turno (do Command), escopo do write path
    # (`remember` tool). Setado no run_pipeline; nil = DEFAULT_TENANT no MemoryStore.
    attr_accessor :tenant

    # Interno (P2B, Tool Search): ids de side-effects já concluídos no turno
    # interrompido, propagados às tools PROMOVIDAS pelo tool_search (mesmo `skip`
    # que o wrap_tools das eager recebe). Setado no run_pipeline pela task 10;
    # nil = turno novo (Array(nil) => []).
    attr_accessor :skip_side_effects

    # P2-02: gate de aprovação. `requires_approval` = nomes de tools que exigem
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

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

    def initialize(task:, profile:, turn:, message:)
      @task = task
      @profile = profile
      @turn = turn
      @message = message
    end
  end
end

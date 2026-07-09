# frozen_string_literal: true

require "async"
require "delegate"

module Harness
  # Envolve cada tool permitida (doc 03 §5, doc 02 §2-§3): timeout por call (D4)
  # + registro de side-effect não-idempotente ANTES de o resultado voltar ao
  # modelo. Delega todo o resto (name/description/params) à tool real.
  #
  # O loop de tools é do RubyLLM; este é um decorator sobre as instâncias — o
  # Executor nunca dirige roundtrips.
  class ToolEnvelope < SimpleDelegator
    # Classe PRÓPRIA do timeout de tool: distinta de Async::TimeoutError para
    # que o rescue abaixo NUNCA engula o timeout de TURNO (que usa o default do
    # with_timeout). Sem isso, um turno estourando enquanto o fiber está dentro
    # de uma tool seria mascarado como timeout de tool e o turno seguiria além
    # do deadline (defeito de durabilidade D4).
    ToolTimeout = Class.new(StandardError)
    private_constant :ToolTimeout

    def initialize(tool, state:, checkpoint_store:, tool_registry:, timeout:,
                   skip_side_effects: [])
      super(tool)
      @state = state
      @checkpoint_store = checkpoint_store
      @tool_registry = tool_registry
      @timeout = timeout
      @skip_side_effects = Array(skip_side_effects) # ids já concluídos no turno interrompido
    end

    # Ponto de entrada que o RubyLLM invoca (Tool#call na versão pinada).
    # Estouro do timeout volta ao MODELO como erro serializado (D4) — não
    # derruba o turno.
    def call(args)
      # doc 02 L5 / doc 03 §4.1: tool call não-idempotente JÁ CONCLUÍDA no turno
      # interrompido -> responder com marcador, NUNCA reexecutar. O marcador
      # volta ao modelo, mantendo o protocolo de tool-use íntegro.
      call_id = @state.current_tool_call&.id
      return { "skipped" => "already_executed" } if call_id && @skip_side_effects.include?(call_id)

      result = Async::Task.current.with_timeout(@timeout, ToolTimeout) { __getobj__.call(args) }
      record_side_effect! if side_effect?
      result
    rescue ToolTimeout
      { error: "TimeoutError: tool excedeu #{@timeout}s" }
    end

    private

    def side_effect?
      @tool_registry.respond_to?(:side_effect?) &&
        @tool_registry.side_effect?(__getobj__.name)
    end

    # Escrito ANTES de o resultado da tool voltar ao modelo (doc 02 §2). Sem
    # tool_call corrente correlacionado, não há o que registrar.
    def record_side_effect!
      id = @state.current_tool_call&.id or return

      @checkpoint_store.record_side_effect(@state.task.id, turn: @state.turn,
                                                           tool_call_id: id)
    end
  end
end

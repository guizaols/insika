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
      call_id = correlation_id
      return { "skipped" => "already_executed" } if call_id && @skip_side_effects.include?(call_id)

      # Gate de aprovação (P2-02): tool marcada `approval` suspende o turno em
      # :waiting até o operador resolver. Delega ao coordenador (o Executor), que
      # cria/consulta o PendingAction e bloqueia via a mailbox. Rejeição volta ao
      # MODELO como erro (turno segue — L5), não derruba o turno. CancelledError/
      # TimeoutError da espera propagam (não são ToolTimeout).
      if approval_required?
        decision = @state.approval_coordinator.request_approval(
          task: @state.task, turn: @state.turn, tool: real_name, args: args, actor: @state.actor
        )
        return { error: "rejected by operator" } unless decision.to_s == "approved"
      end

      result = Async::Task.current.with_timeout(@timeout, ToolTimeout) { __getobj__.call(args) }
      record_side_effect!(call_id) if side_effect?
      result
    rescue ToolTimeout
      { error: "TimeoutError: tool excedeu #{@timeout}s" }
    end

    private

    # impl_name real quando o delegate é um Capability::ResolvedTool (P2B D4/L7):
    # side_effect?/approval/correlação operam sobre o nome REAL registrado no
    # tool_registry (o apelido da capability não existe lá). Tool direta = #name
    # (comportamento Fase 1 inalterado).
    def real_name
      __getobj__.respond_to?(:impl_name) ? __getobj__.impl_name.to_s : __getobj__.name.to_s
    end

    # A tool corrente exige aprovação? (nomes vêm da Resolution via state).
    def approval_required?
      @state.respond_to?(:requires_approval) &&
        Array(@state.requires_approval).include?(real_name)
    end

    # Correlação da call: o id do provider (chat RubyLLM, via before_tool_call)
    # quando existe; senão o NOME da tool — o caso do workflow (doc 03 §4.1), que
    # chama as instâncias direto e não tem id gerado pelo provider.
    # LIMITAÇÃO (Fase 1): a correlação por nome é per-TOOL, não per-call. Se um
    # workflow chama a MESMA tool side-effect mais de uma vez num turno,
    # a retomada pula TODAS as chamadas daquele nome (over-skip) — checkpoint
    # por passo é Fase 2 (doc 03 §4.1). Uma chamada por tool é segura.
    def correlation_id
      (@state.current_tool_call&.id || real_name).to_s
    end

    def side_effect?
      @tool_registry.respond_to?(:side_effect?) &&
        @tool_registry.side_effect?(real_name)
    end

    # Escrito ANTES de o resultado da tool voltar ao modelo (doc 02 §2).
    def record_side_effect!(call_id)
      return if call_id.to_s.empty?

      @checkpoint_store.record_side_effect(@state.task.id, turn: @state.turn,
                                                           tool_call_id: call_id)
    end
  end
end

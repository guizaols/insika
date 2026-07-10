# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (P2-02): o operador resolve uma ação pendente
    # (human-in-the-loop). Resolve o PendingAction no store (fonte da verdade,
    # durável) e ACORDA o turno suspenso em :waiting postando :approval no fiber
    # vivo. Ordem importa: RESOLVE antes de postar — quando o await acorda, o
    # store já tem a decisão (request_approval a relê de lá). Crash-safe: sem
    # fiber vivo o post é no-op; o recovery reexecuta e usa a decisão durável.
    #
    # Payload `{ pending_id:, decision: "approved"|"rejected", operator?: }`.
    # -> PendingAction resolvida.
    class ApproveAction
      def initialize(pending_action_store:, executor:, event_stream:)
        @pending_action_store = pending_action_store
        @executor = executor
        @event_stream = event_stream
      end

      def call(command)
        p = command.payload
        pending_id = (p[:pending_id] || p["pending_id"]).to_s
        decision = (p[:decision] || p["decision"]).to_s
        raise Harness::ValidationError, "pending_id é obrigatório" if pending_id.empty?

        # operador: da auth do operador (Control UI, task 12) via payload; nil ok.
        operator = p[:operator] || p["operator"] || command.meta[:operator]

        # resolve() valida a decisão e o estado (:pending); NotFound se ausente.
        resolved = @pending_action_store.resolve(pending_id, decision: decision, operator: operator)

        @executor.approve(resolved.task_id) # acorda o fiber vivo (no-op se caiu)
        @event_stream.emit(Harness::Event.new(
                             type: :approval_resolved,
                             data: { pending_id: pending_id, decision: resolved.status,
                                     task_id: resolved.task_id, resolved_by: operator },
                             meta: { task_id: resolved.task_id, at: Time.now.utc.iso8601 }
                           ))
        resolved
      end
    end
  end
end

# frozen_string_literal: true

module Harness
  module Commands
    # Command de TURNO (D3, o 5º da Fase 1): dispara um workflow. Reusa a pipeline
    # canônica — só o estágio 6 varia (Executor, doc 03 §4.1). Valida tudo
    # síncrono e responde `{task_id:}` imediato. A allowlist de workflow NÃO é
    # checada aqui: é enforcement do estágio 3 via WorkflowAllowlist (doc 05 §2)
    # -> PolicyDenied -> task :failed.
    class TriggerWorkflow
      ALLOWED_KEYS = %i[workflow agent input session_id].freeze

      def initialize(profiles:, session_store:, task_store:, executor:, workflow_registry:)
        @profiles = profiles
        @session_store = session_store
        @task_store = task_store
        @executor = executor
        @workflow_registry = workflow_registry
      end

      def call(command)
        p = normalize(command.payload)
        reject_unknown_keys!(command.payload) # validação estrita (doc 03 §7)

        workflow = p[:workflow].to_s
        raise Harness::ValidationError, "workflow é obrigatório" if workflow.empty?

        agent = p[:agent].to_s
        raise Harness::ValidationError, "agent é obrigatório" if agent.empty?

        profile = @profiles[agent] ||
                  (raise Harness::NotFoundError, "agente '#{agent}' não configurado")

        input = p[:input] || {}
        raise Harness::ValidationError, "input deve ser um Hash" unless input.is_a?(Hash)

        if p[:session_id]
          @session_store.find(p[:session_id]) ||
            (raise Harness::NotFoundError, "sessão '#{p[:session_id]}' não encontrada")
        end

        # existência validável sem executar — names, NUNCA resolve (não instanciar
        # fora do fiber).
        unless @workflow_registry.names.include?(workflow)
          raise Harness::NotFoundError, "workflow '#{workflow}' não registrado"
        end

        task = @task_store.create(command: command.to_h, session_id: p[:session_id])
        @executor.spawn(task, profile: profile)
        { task_id: task.id }
      end

      private

      def normalize(payload)
        {
          workflow: payload[:workflow] || payload["workflow"],
          agent: payload[:agent] || payload["agent"],
          input: payload[:input] || payload["input"],
          session_id: payload[:session_id] || payload["session_id"]
        }
      end

      def reject_unknown_keys!(payload)
        extra = payload.keys.map(&:to_sym) - ALLOWED_KEYS
        raise Harness::ValidationError, "chaves desconhecidas no payload: #{extra.join(', ')}" unless extra.empty?
      end
    end
  end
end

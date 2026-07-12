# frozen_string_literal: true

module Harness
  module Commands
    # Command de turno canônico: valida tudo síncrono, cria a Task, dispara
    # o fiber e responde `{task_id:}` imediato — o resultado flui pelo Event
    # Stream. Validações que falham NÃO criam Task
    # (ValidationError/NotFoundError -> resposta HTTP direta).
    class SendMessage
      def initialize(profiles:, session_store:, task_store:, executor:)
        @profiles = ProfileSource.coerce(profiles)
        @session_store = session_store
        @task_store = task_store
        @executor = executor
      end

      def call(command)
        p = normalize(command.payload) # aceita chaves string e símbolo

        agent = p[:agent].to_s
        raise Harness::ValidationError, "agent é obrigatório" if agent.empty?

        profile = @profiles[agent] ||
                  (raise Harness::NotFoundError, "agente '#{agent}' não configurado")

        message = p[:message]
        raise Harness::ValidationError, "message é obrigatória e não-vazia" if message.to_s.strip.empty?

        # session_id XOR history (ambos -> erro; nenhum -> one-shot).
        if p[:session_id] && p[:history]
          raise Harness::ValidationError, "session_id e history são mutuamente exclusivos (D2)"
        end

        validate_history!(p[:history]) if p[:history]
        if p[:session_id]
          @session_store.find(p[:session_id]) ||
            (raise Harness::NotFoundError, "sessão '#{p[:session_id]}' não encontrada")
        end

        # command.to_h persiste o Command inteiro na Task;
        # o ResumeTask relê payload.message de lá.
        task = @task_store.create(command: command.to_h, session_id: p[:session_id])
        @executor.spawn_in_session(task, profile: profile)
        { task_id: task.id }
      end

      private

      def normalize(payload)
        {
          agent: payload[:agent] || payload["agent"],
          message: payload[:message] || payload["message"],
          session_id: payload[:session_id] || payload["session_id"],
          history: payload[:history] || payload["history"]
        }
      end

      def validate_history!(history)
        ok = history.is_a?(Array) && history.all? do |m|
          m.is_a?(Hash) &&
            !m.values_at(:role, "role").compact.empty? &&
            !m.values_at(:content, "content").compact.empty?
        end
        raise Harness::ValidationError, "history deve ser [{role:, content:}]" unless ok
      end
    end
  end
end

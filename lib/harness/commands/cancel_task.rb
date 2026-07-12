# frozen_string_literal: true

module Harness
  module Commands
    # Command de controle: posta `:cancel` na mailbox in-process da
    # Task e responde síncrono. Payload `{ task_id: String }` -> retorna Task.
    #
    # O cancelamento é COOPERATIVO: quem transiciona o status é o
    # fiber da task ao drenar a mailbox — NUNCA este handler. Cancel de task sem
    # fiber vivo (terminal ou órfã) é no-op idempotente.
    class CancelTask
      # executor: objeto com #cancel(task_id) — a implementação real é
      # `@running[task_id]&.post(:cancel)`; aqui é contrato (duck type).
      def initialize(task_store:, executor:)
        @task_store = task_store
        @executor = executor
      end

      def call(command)
        task_id = command.payload[:task_id] || command.payload["task_id"]
        raise Harness::ValidationError, "task_id é obrigatório" if task_id.to_s.empty?

        task = @task_store.find(task_id)
        raise Harness::NotFoundError, "task '#{task_id}' não encontrada" unless task

        @executor.cancel(task_id) # no-op se não há fiber vivo neste processo
        # Não transiciona status nem mexe no mailbox_state persistido: só se usa
        # a mailbox in-process (Async::Queue). Devolve o estado corrente pós-post.
        @task_store.find(task_id)
      end
    end
  end
end

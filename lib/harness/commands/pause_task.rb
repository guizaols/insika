# frozen_string_literal: true

module Harness
  module Commands
    # Command de controle: posta `:pause` na mailbox in-process
    # da Task e responde síncrono. Payload `{ task_id: String }` -> retorna Task.
    #
    # Cooperativo: quem transiciona `running -> paused` e emite
    # `:task_paused` é o fiber da task ao drenar na próxima fronteira — NUNCA este
    # handler. Pause de task sem fiber vivo (terminal/órfã) é no-op idempotente.
    class PauseTask
      def initialize(task_store:, executor:)
        @task_store = task_store
        @executor = executor
      end

      def call(command)
        task_id = command.payload[:task_id] || command.payload["task_id"]
        raise Harness::ValidationError, "task_id é obrigatório" if task_id.to_s.empty?

        task = @task_store.find(task_id)
        raise Harness::NotFoundError, "task '#{task_id}' não encontrada" unless task

        @executor.pause(task_id) # no-op se não há fiber vivo neste processo
        @task_store.find(task_id) # estado corrente pós-post
      end
    end
  end
end

# frozen_string_literal: true

require "async"
require "async/queue"

module Harness
  # Fase 1 do modelo de Actor (RFC-0002 §9): um fiber Async por Task + mailbox
  # mínima. Cancelamento cooperativo (RFC-0001 princípio 7, doc 03 L2): o drain
  # só acontece nas fronteiras de estágio/turno, nunca no meio de uma operação.
  class TaskActor
    # :user_message é RESERVADO na Fase 1: o enum e o consumo existem, mas
    # nenhum Command/rota o produz ainda (doc 03 §2). Mantido para o contrato
    # não mudar na Fase 2.
    MESSAGES = %i[cancel user_message].freeze

    attr_reader :task_id, :pending_user_messages

    def initialize(task_id:, parent: Async::Task.current)
      @task_id = task_id
      @parent = parent
      @mailbox = Async::Queue.new
      @pending_user_messages = []
    end

    # Não-bloqueante (doc 03 §5). Mensagem fora do enum é bug do chamador.
    def post(message, data = nil)
      raise ArgumentError, "mensagem desconhecida: #{message}" unless MESSAGES.include?(message)

      @mailbox.enqueue([message, data])
      nil
    end

    # Roda o bloco num fiber Async FILHO do parent (estrutura parent→children:
    # cancelar a task cancela a subárvore, doc 03 §5). Retorna o Async::Task.
    def run(&turn_block)
      @async_task = @parent.async { turn_block.call(self) }
    end

    # Drena a mailbox SEM bloquear (fila vazia = retorna). Chamado pelo Executor
    # só nas fronteiras (cancelamento cooperativo, L2):
    #   :cancel       -> raise CancelledError (quem mapeia p/ :cancelled é o
    #                    topo do fiber no Executor, L3 — não aqui)
    #   :user_message -> acumula em pending_user_messages (sem produtor na Fase 1)
    def drain!
      until @mailbox.empty?
        message, data = @mailbox.dequeue
        case message
        when :cancel then raise CancelledError, "task #{@task_id} cancelada"
        when :user_message then @pending_user_messages << data
        end
      end
      nil
    end

    # specs/boot aguardam o término do fiber.
    def wait = @async_task&.wait
  end
end

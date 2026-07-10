# frozen_string_literal: true

require "async"
require "async/queue"

module Harness
  # Pub/sub in-process (RFC-0002 §7, doc 03 §2). O stream é concorrente ao
  # turno: um observador lento NUNCA atrasa a execução (L4) — cada assinante
  # tem fila própria e `emit` só enfileira. Sem mutex: um reactor, fibers
  # cooperativos (doc 00 §5.5) — um Array simples basta.
  class EventStream
    # Uma assinatura = uma fila. O consumidor bloqueia no `each` (fiber dele),
    # nunca o emissor.
    class Subscription
      CLOSED = Object.new # sentinela interna de fim-de-stream
      private_constant :CLOSED

      # Cap de eventos enfileirados por assinante (doc 07 §5). Um consumidor
      # lento acumula na PRÓPRIA fila; ao exceder, a subscription fecha com um
      # evento :error local — o turno nunca espera transporte (L4).
      MAX_QUEUED = 1000

      def initialize(task_id: nil, session_id: nil, on_close: nil)
        @task_id = task_id
        @session_id = session_id
        @on_close = on_close
        @queue = Async::Queue.new
      end

      # Liga a subscription a um task_id APÓS a criação (doc 07 §4, task 24): o
      # transporte assina antes do dispatch — quando o task_id ainda não existe
      # — e o vincula assim que o handler retorna. Isso mantém o cap por-task
      # honesto (só eventos DESTA task entram na fila) e faz o :error de overflow
      # sair com o task_id correto. Retorna self para encadear.
      def bind(task_id:)
        @task_id = task_id
        self
      end

      # Filtro por meta (D5): nil = casa qualquer valor. Eventos sem task_id no
      # meta (ex.: :session_created) só chegam a subscribers sem filtro de task.
      def matches?(event)
        meta = event.meta || {}
        (@task_id.nil? || meta[:task_id] == @task_id) &&
          (@session_id.nil? || meta[:session_id] == @session_id)
      end

      # Enfileira sem NUNCA bloquear. A profundidade real da fila é `@queue.size`
      # (não um contador à parte — evita drift). Ao atingir o cap, enfileira um
      # :error local e fecha; pushes após o close são ignorados (`@closed`).
      def push(event)
        return if @closed

        if @queue.size >= MAX_QUEUED
          @queue.enqueue(Harness::Event.new(
                           type: :error,
                           data: { message: "subscription overflow" },
                           meta: { task_id: @task_id, session_id: @session_id }
                         ))
          close
          return
        end

        @queue.enqueue(event)
      end

      # Bloqueia o fiber do CONSUMIDOR até #close.
      def each
        while (event = @queue.dequeue) != CLOSED
          yield event
        end
      end

      # Idempotente: um segundo CLOSED é inofensivo (o `each` para no primeiro).
      # `@on_close` só dispara uma vez (evita remover a subscription 2x).
      def close
        return if @closed

        @closed = true
        @queue.enqueue(CLOSED)
        @on_close&.call(self)
      end
    end

    def initialize
      @subscriptions = []
    end

    # NUNCA levanta: a exceção de um observador é isolada (doc 03 §2) — um
    # observador quebrado não derruba o turno. Síncrono e barato (L4/§5).
    #
    # Itera sobre um SNAPSHOT (`dup`): o cap de uma subscription pode fechá-la
    # DURANTE o push (overflow -> close -> on_close remove do array); mutar o
    # array no meio de um Array#each puro pularia o próximo assinante.
    def emit(event)
      @subscriptions.dup.each do |sub|
        sub.push(event) if sub.matches?(event)
      rescue StandardError
        # observador quebrado não derruba o turno; nada a propagar
      end
      nil
    end

    # nil/nil = todos os eventos. Retorna a Subscription (o chamador itera com
    # `#each` no próprio fiber).
    def subscribe(task_id: nil, session_id: nil)
      sub = Subscription.new(task_id: task_id, session_id: session_id,
                             on_close: ->(s) { @subscriptions.delete(s) })
      @subscriptions << sub
      sub
    end
  end
end

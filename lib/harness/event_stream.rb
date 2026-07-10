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
        @queued = 0     # contagem de eventos vivos na fila (push - dequeue)
        @overflowed = false
      end

      # Filtro por meta (D5): nil = casa qualquer valor. Eventos sem task_id no
      # meta (ex.: :session_created) só chegam a subscribers sem filtro de task.
      def matches?(event)
        meta = event.meta || {}
        (@task_id.nil? || meta[:task_id] == @task_id) &&
          (@session_id.nil? || meta[:session_id] == @session_id)
      end

      # Enfileira sem NUNCA bloquear (O(1)). Após o cap, enfileira um :error
      # local e fecha; pushes seguintes são ignorados (já em overflow).
      def push(event)
        return if @overflowed

        if @queued >= MAX_QUEUED
          @overflowed = true
          @queue.enqueue(Harness::Event.new(
                           type: :error,
                           data: { message: "subscription overflow" },
                           meta: { task_id: @task_id, session_id: @session_id }
                         ))
          close
          return
        end

        @queued += 1
        @queue.enqueue(event)
      end

      # Bloqueia o fiber do CONSUMIDOR até #close.
      def each
        while (event = @queue.dequeue) != CLOSED
          @queued -= 1 unless @overflowed # o :error de overflow não entra na conta
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
    def emit(event)
      @subscriptions.each do |sub|
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

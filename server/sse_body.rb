# frozen_string_literal: true

require "json"
require "async"
require "async/queue"

module Harness
  module Server
    # Corpo de resposta SSE (evolui a `SSEStream` da Fase 0). A `SSEStream`
    # recebia um bloco produtor (o Runner escrevia nela); a `SSEBody` DRENA uma
    # `Subscription` do EventStream (doc 07 §2, doc 03 §2): cada assinante tem
    # fila própria; `#each` bloqueia o fiber do CONSUMIDOR até a subscription
    # fechar. O wire é EXATAMENTE `Event#to_h` (D5).
    class SSEBody
      PING = ": ping\n\n" # comentário SSE — não polui o consumidor

      # subscription: qualquer objeto com #each (yield de Events) e #close.
      # heartbeat: segundos de silêncio antes de emitir um ping (L6: 15s
      # atravessa idle timeouts de ALB/nginx de 60s com folga).
      def initialize(subscription:, heartbeat: 15)
        @subscription = subscription
        @heartbeat = heartbeat
      end

      # Sob Falcon isto stream-a de verdade. Precisa de um reactor corrente
      # (Falcon fornece; nos testes, envolver em Async/Sync).
      def each
        internal = Async::Queue.new
        closed = Object.new # sentinela de fim-de-subscription

        # Fiber filho: drena a subscription para uma fila interna e, ao fechar,
        # empurra o sentinela. Isola o bloqueio do `#each` da subscription do
        # loop de heartbeat — sem tocar no núcleo (doc 07 §4).
        producer = Async do
          @subscription.each { |event| internal.enqueue(event) }
        ensure
          internal.enqueue(closed)
        end

        loop do
          event =
            begin
              Async::Task.current.with_timeout(@heartbeat) { internal.dequeue }
            rescue Async::TimeoutError
              :heartbeat # nenhum evento em `heartbeat`s -> ping
            end

          if event.equal?(:heartbeat)
            yield PING
          elsif event.equal?(closed)
            break
          else
            yield "data: #{JSON.generate(event.to_h)}\n\n"
          end
        end
      rescue StandardError
        # Cliente desconectou: sob Falcon o `yield` levanta quando o socket
        # fecha. Nenhuma exceção escapa; a task NUNCA é cancelada aqui — a
        # execução pertence ao runtime, não à conexão (L4). O cliente reconecta
        # em /v1/events?task_id=.
        nil
      ensure
        # Encerra o produtor e FECHA a subscription (senão a fila do subscriber
        # vaza — doc 03 L4). Idempotente.
        producer&.stop
        @subscription.close
      end
    end
  end
end

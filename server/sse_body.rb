# frozen_string_literal: true

require "json"
require "timeout"
require "async"
require "async/queue"

module Harness
  module Server
    # Corpo de resposta SSE (evolui a `SSEStream`). A `SSEStream`
    # recebia um bloco produtor (o Runner escrevia nela); a `SSEBody` DRENA uma
    # `Subscription` do EventStream: cada assinante tem
    # fila própria; `#each` bloqueia o fiber do CONSUMIDOR até a subscription
    # fechar. O wire é EXATAMENTE `Event#to_h`.
    class SSEBody
      PING = ": ping\n\n" # comentário SSE — não polui o consumidor

      # serialize: mapeia um Event -> String (frame SSE) OU nil (evento
      # descartado, sem frame). Default = o wire canônico `data: <Event#to_h>`.
      # O adapter /v1/responses injeta um serializer que produz eventos OpenAI
      # Responses (e pula os que não têm correspondência).
      DEFAULT_SERIALIZE = ->(event) { "data: #{JSON.generate(event.to_h)}\n\n" }

      # subscription: qualquer objeto com #each (yield de Events) e #close.
      # heartbeat: segundos de silêncio antes de emitir um ping (15s
      # atravessa idle timeouts de ALB/nginx de 60s com folga).
      def initialize(subscription:, heartbeat: 15, serialize: nil)
        @subscription = subscription
        @heartbeat = heartbeat
        @serialize = serialize || DEFAULT_SERIALIZE
      end

      # STREAMING BODY do Rack 3 (`#call(stream)`), NÃO `#each`. Sob
      # protocol-rack/protocol-http1 (a pilha do Async::HTTP::Server E do Falcon),
      # um body que responde a `#each` é roteado para Body::Enumerable, cujo
      # `read` roda o `#each` num Fiber COMUM de Enumerator (não um Async::Task) —
      # ali `Async::Task.current` levanta "No async task available", o loop morria
      # engolido no rescue e o corpo saía VAZIO. Expondo `#call` (e NÃO `#each`),
      # o body é roteado para Body::Streaming, que agenda o bloco via
      # Fiber.schedule sob o scheduler do reactor — daí a subscription drena e os
      # frames vão pro socket de verdade (incremental).
      #
      # O `stream` (Protocol::HTTP::Body::Stream) responde a #write/#close. Drena a
      # subscription DIRETO (sem Async::Task.current): quando este fiber bloqueia
      # esperando o próximo evento, o scheduler roda o writer, que empurra o frame
      # já escrito pro socket. Heartbeat via Timeout.timeout (hook do scheduler),
      # que funciona no fiber agendado — mantém a conexão viva no idle (L4).
      def call(stream)
        drain(stream)
      rescue StandardError
        # Cliente desconectou: `stream.write` levanta quando o socket fecha.
        # Nenhuma exceção escapa; a task do turno NUNCA é cancelada aqui — a
        # execução pertence ao runtime, não à conexão (reconecta em /v1/events).
        nil
      ensure
        @subscription.close
        stream.close
      end

      private

      def drain(stream)
        internal = Async::Queue.new
        closed = Object.new # sentinela de fim-de-subscription

        # Fiber filho (agendado no scheduler do reactor): drena a subscription
        # para uma fila interna e, ao fechar, empurra o sentinela. Isola o
        # bloqueio da subscription do loop de heartbeat. Encerra sozinho quando o
        # `@subscription.close` (no ensure do #call) faz o `each` terminar — sem
        # precisar matar o fiber à mão.
        Fiber.schedule do
          @subscription.each { |event| internal.enqueue(event) }
        ensure
          internal.enqueue(closed)
        end

        loop do
          event =
            begin
              Timeout.timeout(@heartbeat) { internal.dequeue }
            rescue Timeout::Error
              :heartbeat # nenhum evento em `heartbeat`s -> ping
            end

          if event.equal?(:heartbeat)
            stream.write(PING)
          elsif event.equal?(closed)
            break
          elsif (frame = @serialize.call(event))
            stream.write(frame)
          end
        end
      end
    end
  end
end

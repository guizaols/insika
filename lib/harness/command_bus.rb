# frozen_string_literal: true

module Harness
  # Roteia Commands para handlers registrados pelo composition root (doc 03 §2).
  # O bus NÃO distingue Commands de controle (resposta síncrona) de Commands de
  # turno (`{task_id:}` imediato) — isso é do handler; o bus só roteia.
  #
  # Sem lock/mutex: um reactor, fibers cooperativos (doc 00 §5.5); `dispatch`
  # não faz IO próprio.
  class CommandBus
    # event_stream: guardado para uso futuro (ex.: auditoria de dispatch na
    # Fase 2). Handlers recebem suas dependências no próprio construtor e
    # emitem por conta própria nesta fase (doc 03 §2, Notes da task).
    def initialize(event_stream:)
      @event_stream = event_stream
      @handlers = {}
    end

    # handler: qualquer objeto que responda a #call(command). Re-registrar o
    # mesmo tipo sobrescreve (último vence — o composition root é o único
    # chamador).
    def register(type, handler)
      @handlers[type.to_sym] = handler
    end

    # -> resultado do handler. Tipo não registrado -> ValidationError síncrono,
    # nenhuma Task criada (D4, linha "Command Bus"; nunca KeyError/NoMethodError).
    def dispatch(command)
      handler = @handlers[command.type]
      raise Harness::ValidationError, "command desconhecido: #{command.type}" if handler.nil?

      handler.call(command)
    end
  end
end

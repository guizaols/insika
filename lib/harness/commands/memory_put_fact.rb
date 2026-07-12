# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: grava um fato estável na memória
    # do agente (MemoryStore, camada `profile`). Até agora a memória só era escrita
    # de DENTRO do turno (tool `remember`); este Command é a superfície HTTP que o
    # Studio usa pra editar fatos direto. Escopado por `tenant` (nil = _default).
    # Síncrono; não cria Task. -> Fact.
    class MemoryPutFact
      def initialize(memory_store:, event_stream:)
        @memory_store = memory_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        key = AgentPayload.presence(p[:key])
        raise Harness::ValidationError, "key é obrigatório" if key.nil?
        raise Harness::ValidationError, "value é obrigatório" if p[:value].nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        fact = @memory_store.put_fact(tenant: tenant, key: key, value: p[:value])
        @event_stream.emit(Harness::Event.new(
                             type: :memory_fact_put,
                             data: { tenant: tenant, key: key },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        fact
      end
    end
  end
end

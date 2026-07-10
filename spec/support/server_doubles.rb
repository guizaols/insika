# frozen_string_literal: true

# Duplos compartilhados pelos specs do harness-server (task 24). Vivem em
# spec/support para não depender de vazamento de constantes entre arquivos (a
# suíte roda em ordem aleatória).

# Bus duplo: grava os Commands despachados e responde pelo bloco injetado.
class ServerBusDouble
  attr_reader :dispatched

  def initialize(&responder)
    @dispatched = []
    @responder = responder || ->(_c) { {} }
  end

  def dispatch(command)
    @dispatched << command
    @responder.call(command)
  end
end

# Subscription falsa: entrega eventos roteirizados de forma síncrona e grava
# se foi fechada.
class ServerFakeSubscription
  attr_reader :closed

  def initialize(events)
    @events = events
    @closed = false
  end

  def each
    @events.each { |e| yield e }
  end

  def close = (@closed = true)
end

# EventStream duplo: grava os filtros pedidos e devolve a subscription falsa.
class ServerEventStreamDouble
  attr_reader :subscribes

  def initialize(events = [])
    @events = events
    @subscribes = []
  end

  def subscribe(task_id: nil, session_id: nil)
    @subscribes << { task_id: task_id, session_id: session_id }
    ServerFakeSubscription.new(@events)
  end
end

# Store duplo: grava os ids consultados e devolve um record fixo.
class ServerStoreDouble
  attr_reader :queried

  def initialize(record)
    @record = record
    @queried = []
  end

  def find(id)
    @queried << id
    @record
  end
end

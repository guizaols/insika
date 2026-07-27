# frozen_string_literal: true

# Doubles shared by the insika-server specs (task 24). They live in spec/support so
# as not to depend on constant leakage between files (the suite runs in random
# order).

# Bus double: records the dispatched Commands and responds via the injected block.
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

# Fake subscription: delivers scripted events synchronously and records whether it
# was closed.
class ServerFakeSubscription
  attr_reader :closed

  def initialize(events)
    @events = events
    @closed = false
  end

  def each
    @events.each { |e| yield e }
  end

  # Parity with the real Subscription (task 24): the transport binds the task_id
  # after the dispatch. In the double it's a no-op (the events already come scripted).
  def bind(task_id:) = self

  def close = (@closed = true)
end

# EventStream double: records the requested filters, returns the fake subscription
# and records the emitted events (audit of the write /admin).
class ServerEventStreamDouble
  attr_reader :subscribes, :emitted

  def initialize(events = [])
    @events = events
    @subscribes = []
    @emitted = []
  end

  def subscribe(task_id: nil, session_id: nil)
    @subscribes << { task_id: task_id, session_id: session_id }
    ServerFakeSubscription.new(@events)
  end

  def emit(event) = (@emitted << event)
end

# Store double: records the queried ids and returns a fixed record.
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

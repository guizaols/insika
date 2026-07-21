# frozen_string_literal: true

module Harness
  # Routes Commands to handlers registered by the composition root.
  # The bus does NOT distinguish control Commands (synchronous response) from
  # turn Commands (immediate `{task_id:}`) — that is the handler's job; the bus
  # only routes.
  #
  # No lock/mutex: one reactor, cooperative fibers; `dispatch`
  # does no IO of its own.
  class CommandBus
    # Handlers receive their dependencies in their own constructor and emit on
    # their own — the bus only routes.
    def initialize
      @handlers = {}
    end

    # handler: any object responding to #call(command). Re-registering the
    # same type overwrites (last wins — the composition root is the only
    # caller).
    def register(type, handler)
      @handlers[type.to_sym] = handler
    end

    # Introspection for the composition roots / graph specs: which command
    # types the bus can route. Read-only; does not expose the handlers.
    def registered?(type) = @handlers.key?(type.to_sym)
    def types = @handlers.keys

    # -> the handler's result. Unregistered type -> synchronous ValidationError,
    # no Task created (never KeyError/NoMethodError).
    def dispatch(command)
      handler = @handlers[command.type]
      raise Harness::ValidationError, "unknown command: #{command.type}" if handler.nil?

      handler.call(command)
    end
  end
end

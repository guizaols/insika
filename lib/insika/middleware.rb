# frozen_string_literal: true

module Insika
  # A link in the chain (stage 4). A Middleware MODIFIES the TurnState,
  # short-circuits, and has operational effect (rate limit, tracing, cost) — it
  # does NOT decide tool/skill permission (that is Policy). Short-circuit =
  # NOT calling `nxt` and setting `state.halt_reason`. Setting halt_reason AND
  # calling nxt is a contract violation (the Executor prioritizes halt_reason on
  # the way back).
  #
  # Concurrency: it runs on the task's fiber; IO (e.g. a tracing exporter)
  # must be async off the path (`Async { ... }` fire-and-forget) or accept
  # the latency in the turn. No timeout of its own (covered by the turn timeout).
  class Middleware
    def call(state, &nxt)
      nxt.call(state) # default link: pass-through
    end
  end

  # Rack-like composition: registration order = execution order (the first is
  # the outermost link). It does NOT rescue (an exception propagates as a turn
  # failure) nor does it have a special halt mechanism — the short-circuit is
  # structural (the link does not call nxt).
  class MiddlewareStack
    def initialize(middlewares = [])
      @middlewares = middlewares
    end

    # Appends a link at the END (innermost). This is the plugin Loader's
    # registration seam ("collections that respond to <<") — it runs at boot,
    # single-fiber, before the server accepts connections, so appending here
    # never races a turn.
    def <<(middleware)
      @middlewares << middleware
      self
    end

    def call(state, &terminal)
      chain = @middlewares.reverse.reduce(terminal) do |nxt, mw|
        proc { |s| mw.call(s, &nxt) }
      end
      chain.call(state)
    end
  end
end

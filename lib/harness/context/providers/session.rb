# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Reads the Session Store. The ONLY history provider: the three transcript
      # sources converge here — the Executor does not pick a source. Produces
      # :history fragments (1 per message), with priority scaled by recency
      # with a CEILING of 79: the budget cut discards the oldest ones first
      # and history NEVER outranks skills (80) or identity (100).
      class Session < ContextProvider
        def initialize(session_store:)
          @session_store = session_store
        end

        def call(request)
          messages = transcript_for(request)
          return [] if messages.nil? || messages.empty?

          messages.each_with_index.map do |msg, idx|
            ContextFragment.build(
              content: { role: msg[:role] || msg["role"], content: msg[:content] || msg["content"] },
              placement: :history,
              # HISTORY_MAX ceiling; idx 0 = oldest (drops first in the cut)
              priority: [Context::Priority::HISTORY_BASE + idx, Context::Priority::HISTORY_MAX].min,
              source: id
            )
          end
        end

        private

        # Precedence: checkpoint -> explicit history -> store.
        # The first present source wins; no merge.
        def transcript_for(request)
          return request.checkpoint.messages if request.checkpoint

          explicit = explicit_history(request)
          return explicit if explicit
          return session_messages(request.session) if request.session

          nil
        end

        # Source 2 (explicit history): the handler passes it in request.vars[:history].
        # Isolated in a single method to change the convention with 1 line.
        def explicit_history(request)
          vars = request.vars.to_h
          vars[:history] || vars["history"]
        end

        # CONDITIONAL requiredness: when a session is requested, a read
        # failure becomes a ContextError (aborts the turn); the base required?
        # does not receive the request, so the behavior lives here.
        def session_messages(session)
          @session_store.find(session.id)&.messages || []
        rescue StandardError => e # read failure (exception/StoreError)
          raise ContextError.new("Session provider failed with a requested session: #{e.message}",
                                 provider: id)
        end
      end
    end
  end
end

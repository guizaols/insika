# frozen_string_literal: true

module Insika
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

          # 1 fragment per EVICTION UNIT (§11 R1): a plain message, OR an
          # assistant-with-tool_calls together with its tool results. Grouping at
          # the fragment level means the budget cut (apply_budget) drops a whole
          # tool cycle atomically — a tool_use is NEVER seeded without its result
          # (which providers reject), without touching apply_budget itself.
          eviction_units(messages).each_with_index.map do |unit, idx|
            ContextFragment.build(
              # single message stays a Hash (compat with existing fragments); a
              # multi-message cycle is an Array (seed_history flattens it back).
              content: unit.size == 1 ? unit.first : unit,
              placement: :history,
              # HISTORY_MAX ceiling; idx 0 = oldest (drops first in the cut)
              priority: [Context::Priority::HISTORY_BASE + idx, Context::Priority::HISTORY_MAX].min,
              source: id
            )
          end
        end

        private

        # Groups a flat message list into eviction units. An assistant message
        # carrying tool_calls absorbs the `role: tool` messages that immediately
        # follow it (its results). Everything else is a unit of one.
        def eviction_units(messages)
          normalized = messages.map { |m| normalize(m) }
          units = []
          i = 0
          while i < normalized.length
            msg = normalized[i]
            i += 1
            if msg[:role].to_s == "assistant" && tool_calls?(msg)
              cycle = [msg]
              while i < normalized.length && normalized[i][:role].to_s == "tool"
                cycle << normalized[i]
                i += 1
              end
              units << cycle
            else
              units << [msg]
            end
          end
          units
        end

        # Symbol-keyed message preserving tool_calls / tool_call_id when present
        # (a plain message keeps just {role, content} — parity with the old shape).
        def normalize(msg)
          h = { role: msg[:role] || msg["role"], content: msg[:content] || msg["content"] }
          tool_calls = msg[:tool_calls] || msg["tool_calls"]
          tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]
          h[:tool_calls] = tool_calls if tool_calls
          h[:tool_call_id] = tool_call_id if tool_call_id
          h
        end

        def tool_calls?(msg) = msg[:tool_calls] && !Array(msg[:tool_calls]).empty?

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

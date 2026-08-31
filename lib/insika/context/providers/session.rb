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
          messages, compaction = transcript_for(request)
          return [] if messages.nil? || (messages.empty? && compaction.nil?)

          # A3/C3 opt-in: identical tool results in the transcript collapse to a
          # back-reference (the cheap half of compaction). CHANGES WHAT THE MODEL
          # SEES — hence the profile flag, never a default. Applied BEFORE the
          # eviction-unit grouping so a cycle's results are already slim.
          messages = compress_history(messages, request)

          # 1 fragment per EVICTION UNIT (R1): a plain message, OR an
          # assistant-with-tool_calls together with its tool results. Grouping at
          # the fragment level means the budget cut (apply_budget) drops a whole
          # tool cycle atomically — a tool_use is NEVER seeded without its result
          # (which providers reject), without touching apply_budget itself.
          fragments = eviction_units(messages).each_with_index.map do |unit, idx|
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
          compaction ? [compaction_fragment(compaction)] + fragments : fragments
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

        # The compression is opt-in per agent (profile data, config-over-code):
        # absent/off -> the transcript passes through byte-identical (parity).
        def compress_history(messages, request)
          profile = request.respond_to?(:profile) ? request.profile : nil
          return messages unless profile&.tool_output_compression

          ToolOutputCompressor.compress_transcript(messages)
        end

        # Precedence: checkpoint -> explicit history -> store.
        # The first present source wins; no merge. -> [messages, compaction|nil].
        # The compaction state (RFC-0044) applies to the STORE source only: a
        # checkpoint resume replays the checkpoint's own tape (which already
        # contains whatever summary the original turn saw) and an explicit
        # vars[:history] is the caller's contract — neither is rewritten.
        def transcript_for(request)
          return [request.checkpoint.messages, nil] if request.checkpoint

          explicit = explicit_history(request)
          return [explicit, nil] if explicit
          return compacted_session_messages(request.session) if request.session

          [nil, nil]
        end

        # Splits the stored transcript at the persisted compaction boundary:
        # messages[0...upto] are represented by the summary, messages[upto..]
        # stay verbatim. `upto` is clamped to the transcript size (defensive —
        # the store is append-only, so it should never outrun it).
        def compacted_session_messages(session)
          fresh = fresh_session(session)
          return [[], nil] if fresh.nil?

          messages = fresh.messages || []
          state = fresh.respond_to?(:compaction) ? fresh.compaction : nil
          upto = state ? state["upto"].to_i : 0
          return [messages, nil] unless upto.positive? && Coercion.present?(state["summary"])

          [messages.drop([upto, messages.size].min), state]
        end

        # The compacted prefix as ONE history fragment, rendered FIRST (the
        # Builder keeps history in production order). role "user" because it is
        # provider-agnostic (a mid-history "system" message is not). Priority
        # COMPACTION (59): the "oldest unit" — under budget it drops before any
        # verbatim message. source "compaction" -> its own context-trace category.
        def compaction_fragment(state)
          ContextFragment.build(
            content: { role: "user",
                       content: "<conversation_summary>\n#{state['summary']}\n</conversation_summary>" },
            placement: :history,
            priority: Context::Priority::COMPACTION,
            source: "compaction"
          )
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
        def fresh_session(session)
          @session_store.find(session.id)
        rescue StandardError => e # read failure (exception/StoreError)
          raise ContextError.new("Session provider failed with a requested session: #{e.message}",
                                 provider: id)
        end
      end
    end
  end
end

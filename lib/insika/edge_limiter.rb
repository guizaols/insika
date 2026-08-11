# frozen_string_literal: true

require_relative "middleware"
require_relative "coercion"

module Insika
  # The production edge: THE named place where volume/cost
  # abuse is cut. A Middleware with two independent limits, both OPT-IN
  # (nil/0 = off — a bare wiring behaves exactly as before):
  #
  #   · chat rate limit    — turn ATTEMPTS per chat per window. Counted on entry
  #     (a blocked attempt still counts), so a flood keeps hitting the wall.
  #   · agent token ceiling — total tokens per agent per window. Checked on entry
  #     against the accumulated ledger; the turn's own usage is recorded AFTER the
  #     terminal returns (the Middleware wraps stages 5-9, so state.usage is set).
  #
  # Config resolution, per turn (configuration over convention):
  #   profile.limits[:chat_rate_limit / :agent_token_ceiling]  — per-agent override
  #   settings["edge"]                                          — platform default
  # A per-agent 0 explicitly disables a platform default for that agent.
  #
  # On breach it uses the graceful-halt contract: halt_response
  # (the safe reply) + guardrail_block (audit -> :guardrail_blocked) and does NOT
  # call `nxt` — the turn completes with ZERO LLM calls. It sits BEFORE the
  # InputGuardrail in the stack so a flood can't spend the LLM moderator either.
  class EdgeLimiter < Middleware
    CHAT_KIND   = "chat"
    TOKENS_KIND = "tokens"

    DEFAULT_CHAT_WINDOW   = 60      # seconds
    DEFAULT_TOKEN_WINDOW  = 86_400  # seconds (daily ceiling)

    # Neutral fallback, same contract as Safety::SafeResponses (pt-BR — the
    # pilot's language; override via settings edge.limit_response).
    DEFAULT_RESPONSE = "Estou recebendo muitas mensagens agora. Aguarde um " \
                       "momento e tente novamente, por favor."

    def initialize(ledger:, settings_store: nil)
      @ledger = ledger
      @settings = settings_store
    end

    def call(state, &nxt)
      edge = platform_edge
      limits = state.profile.limits || {}
      # A resume (crash/pause recovery) re-enters the pipeline for a turn that was
      # ALREADY admitted: re-counting it would swallow a legitimate message with
      # the rate-limit reply exactly when the window is saturated. Entry checks
      # are skipped; the turn's usage still lands on the ledger below.
      resumed = state.resumed

      if !resumed && (limit = positive(limits.key?(:chat_rate_limit) ? limits[:chat_rate_limit] : edge["chat_rate_limit"]))
        breach = check_chat_rate(state, limit, edge)
        return block(state, edge, **breach) if breach
      end

      # NB: a per-agent key PRESENT with nil (e.g. an imported pack carrying
      # `"chat_rate_limit": null`) reads as OFF for that agent, not "inherit".
      if (ceiling = positive(limits.key?(:agent_token_ceiling) ? limits[:agent_token_ceiling] : edge["agent_token_ceiling"]))
        token_window = positive(edge["agent_token_window"]) || DEFAULT_TOKEN_WINDOW
        unless resumed
          spent = @ledger.count(TOKENS_KIND, state.profile.id.to_s, window: token_window)
          if spent >= ceiling
            return block(state, edge, category: :token_ceiling,
                                      detail: "agent #{state.profile.id}: #{spent}/#{ceiling} tokens per #{token_window}s")
          end
        end

        record_after = token_window
      end

      result = nxt.call(state)
      record_usage(state, record_after) if record_after
      result
    end

    private

    # One KV get per turn (same order of cost as the guardrail's config read);
    # no SettingsStore in the wiring -> per-agent limits only.
    def platform_edge
      (@settings&.get || {})["edge"] || {}
    end

    # Counts the ATTEMPT first, then compares — the standard fixed-window
    # semantics (blocked attempts keep counting). A blank chat id is skipped:
    # unrelated anonymous traffic must not share one bucket.
    def check_chat_rate(state, limit, edge)
      chat_id = (state.turn_context || {})[:chat_id].to_s
      return nil if chat_id.empty?

      window = positive(edge["chat_rate_window"]) || DEFAULT_CHAT_WINDOW
      taken = @ledger.add(CHAT_KIND, chat_id, window: window)
      return nil if taken <= limit

      { category: :rate_limit, detail: "chat #{chat_id}: #{taken}/#{limit} turns per #{window}s" }
    end

    # The turn's real spend, accumulated on the agent's ledger. The engine's
    # `total_tokens` is input + output and DELIBERATELY excludes the cached
    # prefix (`Executor#usage_of` reports `cached_tokens`/`cache_creation_tokens`
    # alongside it) — on a cached identity that prefix is ~95% of what the
    # provider actually processed, so a ceiling reading only `total_tokens` is
    # blind. Same billed-spend rule as `Evals::Runner#billed_tokens`.
    # nil usage (workflow turn / provider without counts) records nothing.
    def record_usage(state, window)
      usage = state.usage || {}
      tokens = usage[:total_tokens].to_i + usage[:cached_tokens].to_i +
               usage[:cache_creation_tokens].to_i
      return if tokens.zero?

      @ledger.add(TOKENS_KIND, state.profile.id.to_s, window: window, by: tokens)
    end

    # Graceful halt: safe reply + audit metadata, short-circuit (no nxt).
    # `detail` carries only ids/counters — never message content.
    def block(state, edge, category:, detail:)
      state.halt_response = Coercion.presence(edge["limit_response"]) || DEFAULT_RESPONSE
      state.guardrail_block = {
        category: category.to_s, source: "edge", action: "refuse", detail: detail
      }
      nil
    end

    def positive(value)
      v = value.to_i
      v.positive? ? v : nil
    end
  end
end

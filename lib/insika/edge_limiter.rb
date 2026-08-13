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
  #   · calendar budget    — WS2: `AgentProfile#budget` caps the spend per
  #     (tenant, agent) over CALENDAR windows (daily/monthly), on the
  #     BudgetLedger. Hard (default): crossing the cap raises the typed
  #     Insika::BudgetExceeded (the envelope quotes budget_exceeded +
  #     retry_after); soft: crossing warns instead — ONE budget_warning event
  #     per window plus a note injected into the context. Crossing `alert_at`
  #     (default 0.8 of the cap) warns the same way, before the wall. The turn's
  #     billed spend (input+output+cached+cache_creation — the A4 rule) lands on
  #     the windows after the terminal.
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
  # The BUDGET breach is the ONE deliberate exception: it is a typed failure
  # (BudgetExceeded), not a customer-facing reply — the operator wants the
  # envelope to say "budget" and quote when the window rolls, not to hand the
  # customer a cost message.
  class EdgeLimiter < Middleware
    CHAT_KIND   = "chat"
    TOKENS_KIND = "tokens"

    DEFAULT_CHAT_WINDOW   = 60      # seconds
    DEFAULT_TOKEN_WINDOW  = 86_400  # seconds (daily ceiling)

    # Neutral fallback, same contract as Safety::SafeResponses (pt-BR — the
    # pilot's language; override via settings edge.limit_response).
    DEFAULT_RESPONSE = "Estou recebendo muitas mensagens agora. Aguarde um " \
                       "momento e tente novamente, por favor."

    def initialize(ledger:, settings_store: nil, budget_ledger: nil, event_stream: nil)
      @ledger = ledger
      @settings = settings_store
      # WS2: the calendar-window ledger. nil = budget off (parity — the bare
      # wiring is byte-identical to before).
      @budget_ledger = budget_ledger
      @event_stream = event_stream
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

      # WS2: calendar budgets. Entry — a HARD budget at/over the cap raises the
      # typed error (never a customer-facing reply); the alert_at warning and
      # the SOFT over-cap both warn once per window + inject a context note.
      # A resumed turn (crash/pause replay) was already admitted: it is never
      # refused twice — its spend still lands on the ledger below.
      budget_on = budget_configured?(state)
      budget_enforce(state) unless resumed

      result = begin
        nxt.call(state)
      ensure
        # A turn that FAILED after burning tokens still SPENT them: record the
        # usage the state captured before the error propagates. The ask's usage
        # lands on state.usage before any later stage (guardrail block, tool
        # error, workflow schema) can fail the turn — a failed turn must count
        # against the budget like a completed one (WS2).
        record_usage(state, record_after) if record_after
        record_budget_usage(state) if budget_on
      end
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

    # --- WS2 calendar budgets ------------------------------------------

    # -> truthy when a budget is configured AND the ledger is wired.
    def budget_configured?(state)
      budget = state.profile.respond_to?(:budget) ? state.profile.budget : nil
      !budget.nil? && !@budget_ledger.nil?
    end

    # -> truthy (the budget hash) when budget checks ran. Raises BudgetExceeded
    # on a HARD cap breach.
    def budget_enforce(state, now: Time.now)
      budget = state.profile.respond_to?(:budget) ? state.profile.budget : nil
      return nil if budget.nil? || @budget_ledger.nil?

      tenant = budget_tenant(state)
      agent = state.profile.id.to_s
      budget_windows(budget).each do |w|
        spent = @budget_ledger.current(tenant: tenant, agent: agent, now: now)[w[:window]]
        if spent >= w[:cap]
          unless w[:soft]
            raise Insika::BudgetExceeded.new(
              window: w[:window],
              retry_after: @budget_ledger.reset_in(w[:window], now: now)
            )
          end
          warn_budget(state, tenant, agent, w, spent, now, level: "cap")
        elsif spent >= w[:alert_at]
          warn_budget(state, tenant, agent, w, spent, now, level: "alert_at")
        end
      end
      budget
    end

    # The (tenant, agent) scope: the COMMAND's tenant (nil -> the BudgetLedger's
    # "platform" cell) — never state.tenant, which falls back to the session id
    # (a per-chat bucket is not a budget).
    def budget_tenant(state)
      command = state.respond_to?(:task) && state.task&.command
      return nil unless command.is_a?(Hash)

      meta = command["meta"] || command[:meta] || {}
      meta["tenant"] || meta[:tenant]
    end

    # -> [{ window:, cap:, soft:, alert_at: }] — one entry per configured window
    # (a 0/absent cap is off). absent `soft` = FALSE (hard): a limit that does
    # not limit is decoration; the alert_at warning is the soft half.
    def budget_windows(budget)
      alert_at = budget["alert_at"].to_f
      alert_at = 0.8 if alert_at <= 0 || alert_at >= 1
      soft = budget["soft"] == true
      %i[daily monthly].filter_map do |window|
        cap = budget[window.to_s].to_i
        cap.positive? ? { window: window, cap: cap, soft: soft,
                          alert_at: (cap * alert_at).floor } : nil
      end
    end

    # The warning: a note in the context (the model sees it, the customer's
    # transcript does not) + the budget_warning event — each LEVEL once per
    # (window) cell: the `alert_at` crossing and the real soft-cap crossing are
    # separate markers, so the cap event is never swallowed by the 80% one that
    # fired earlier (WS2).
    def warn_budget(state, tenant, agent, w, spent, now, level:)
      inject_budget_note(state,
                         "[budget: agent '#{agent}' is at #{spent}/#{w[:cap]} tokens this " \
                         "#{w[:window]} window — keep this turn cheap]")
      return if @budget_ledger.mark_alert(tenant: tenant, agent: agent, window: w[:window],
                                          level: level, now: now)

      # `tenant` on the META too, not only in the payload: the tenant-scoped
      # /v1/events subscription filters on meta[:tenant] and is fail-closed, so
      # a warning about the tenant's OWN budget never reached the tenant.
      meta = { task_id: state.task&.id, session_id: state.task&.session_id,
               at: Time.now.utc.iso8601 }
      meta[:tenant] = tenant unless tenant.nil?
      @event_stream&.emit(Insika::Event.new(
                            type: :budget_warning,
                            data: { agent: agent, tenant: tenant, window: w[:window],
                                    spent: spent, cap: w[:cap], level: level },
                            meta: meta
                          ))
    end

    # Appends the note to the assembled system prompt: the real Data package is
    # immutable (with), the specs' minimal Struct is mutable — both duck-typed.
    def inject_budget_note(state, note)
      ctx = state.context
      return if ctx.nil?

      if ctx.respond_to?(:with)
        state.context = ctx.with(system: "#{ctx.system}\n\n#{note}")
      elsif ctx.respond_to?(:system=)
        ctx.system = "#{ctx.system}\n\n#{note}"
      end
    end

    # The turn's REAL billed spend (input + output + cached + cache_creation —
    # the A4 rule) on the calendar windows.
    def record_budget_usage(state, now: Time.now)
      usage = state.usage || {}
      tokens = usage[:total_tokens].to_i + usage[:cached_tokens].to_i +
               usage[:cache_creation_tokens].to_i
      return if tokens.zero?

      @budget_ledger.add(tenant: budget_tenant(state), agent: state.profile.id.to_s,
                         by: tokens, now: now)
    end
  end
end

# frozen_string_literal: true

module Studio
  # Form → command-payload parsing for the Studio App. A mixin, NOT a
  # standalone object: `include`d into App so every method keeps `self` == the
  # App instance and reaches its request helpers (`presence`, `split_list`) and
  # per-request state (`@agent`) exactly as before. Pure extraction — the bodies
  # moved verbatim from app.rb; app_spec's POST cases are the safety net.
  module Forms
    # The agent config form OWNS every rendered field: a save reflects the
    # whole form state, so a blank field is a deliberate "clear to default",
    # never a carry-over. The one exception is keys the form cannot express —
    # those ride the `carry` merge below (the guardrails corpora precedent).
    def config_patch(r)
      limits = @agent.limits.dup
      # Always present via DEFAULT_LIMITS (tool_concurrency defaults to 1 = serial),
      # so a blank field just keeps whatever is stored.
      %w[turn_timeout tool_timeout tool_concurrency].each do |field|
        v = presence(r.params[field])
        limits[field.to_sym] = Integer(v) if v
      end
      # Per-agent edge overrides. Unlike the timeouts (always present via
      # DEFAULT_LIMITS), these are OPT-IN keys: blank DELETES the override (inherit
      # the platform edge settings); 0 explicitly disables for this agent.
      %w[chat_rate_limit agent_token_ceiling].each do |field|
        v = edge_int(r.params[field], field)
        if v.nil?
          limits.delete(field.to_sym)
        else
          limits[field.to_sym] = v
        end
      end
      {
        id: @agent.id,
        model: presence(r.params["model"]),
        provider: r.params["provider"].to_s,
        memory: r.params["memory"] == "1",
        limits: limits,
        params: params_patch(r),
        model_policy: model_policy_patch(r),
        guardrails: guardrails_patch(r),
        # Every remaining AgentProfile field is editable here — the pack
        # import is one door, this form is the other (hot, no restart).
        grounding: grounding_patch(r),
        funnel: funnel_patch(r),
        followup: followup_patch(r),
        distill: distill_patch(r),
        harvest: harvest_patch(r),
        refinement: refinement_patch(r),
        budget: budget_patch(r),
        reliability: reliability_patch(r),
        routes: json_patch(r, "routes"),
        outputs: json_patch(r, "outputs"),
        metadata: json_patch(r, "metadata") || {},
        alerts: alerts_patch(r),
        edge_stream: edge_stream_patch(r),
        stuck_signal: r.params["stuck_signal"] == "1",
        prompt_caching: r.params["prompt_caching"] == "1",
        # The one opt-out flag: checked (the rendered default) saves true, an
        # unchecked box saves an explicit false — both spellings of ON collapse.
        tool_persistence: r.params["tool_persistence"] == "1",
        tool_output_compression: r.params["tool_output_compression"] == "1",
        subagents: list_patch(r, "subagents"),
        capabilities: list_patch(r, "capabilities"),
        tools_deferred: list_patch(r, "tools_deferred"),
        briefing_fields: list_patch(r, "briefing_fields"),
        context_providers: allowlist_patch(r, "context_providers"),
        workflows_allow: allowlist_patch(r, "workflows_allow"),
        approvals_required: list_patch(r, "approvals_required"),
        policies: list_patch(r, "policies").map(&:to_sym),
        prompt_refs: list_patch(r, "prompt_refs"),
        capabilities_declared: list_patch(r, "capabilities_declared"),
        skills_eager: skills_eager_patch(r)
      }
    end

    # grounding — { "mode" => "flag"|"enforce", "matcher" =>
    # { "sku" => "sku:…", "name_keys" => [...] } }. Blank mode = no grounding
    # (parity). The matcher keys are carried only while a mode is declared.
    def grounding_patch(r)
      mode = presence(r.params["grounding_mode"])
      return nil unless %w[flag enforce].include?(mode)

      matcher = {}
      (sku = presence(r.params["grounding_matcher_sku"])) && (matcher["sku"] = sku)
      keys = list(r.params["grounding_name_keys"])
      matcher["name_keys"] = keys unless keys.empty?
      { "mode" => mode, "matcher" => matcher }
    end

    # the outcome funnel — the pack's own stage vocabulary, edited
    # hot. Blank stages = no funnel (parity). Stages: one per line.
    def funnel_patch(r)
      stages = lines(r.params["funnel_stages"])
      return nil if stages.empty?

      out = { "stages" => stages }
      (p = presence(r.params["funnel_primary"])) && (out["primary"] = p)
      (w = presence(r.params["funnel_attribution_window"])) && (out["attribution_window"] = w)
      advance = json_block(r.params["funnel_advance_on"], "funnel advance_on")
      out["advance_on"] = advance unless advance.nil? || advance.empty?
      out
    end

    # the follow-up declaration. Blank arm = the feature is off
    # (parity). The policy keys are all rendered; a blank one drops the key.
    def followup_patch(r)
      arm = presence(r.params["followup_arm"])
      return nil unless arm

      policy = {}
      tz = presence(r.params["followup_tz"])
      if tz
        quiet = { "timezone" => tz }
        (s = presence(r.params["followup_quiet_start"])) && (quiet["start"] = s)
        (e = presence(r.params["followup_quiet_end"])) && (quiet["end"] = e)
        policy["quiet_hours"] = quiet
      end
      (f = presence(r.params["followup_max_frequency"])) && (policy["max_frequency"] = f)
      keywords = list(r.params["followup_cancel_keywords"])
      policy["cancel_keywords"] = keywords unless keywords.empty?
      silence = edge_int(r.params["followup_silence_after_sends"], "followup_silence_after_sends")
      policy["silence_after_sends"] = silence unless silence.nil?
      { "arm" => arm, "policy" => policy }
    end

    # distillation — enabled checkbox + the forge's knobs. Blank
    # prompt/model drop the keys (the engine defaults take over).
    def distill_patch(r)
      enabled = r.params["distill_enabled"] == "1"
      out = { "enabled" => enabled }
      (p = presence(r.params["distill_prompt"])) && (out["prompt"] = p)
      (m = presence(r.params["distill_model"])) && (out["model"] = m)
      %w[idle_hours min_messages max_proposals].each do |key|
        v = edge_int(r.params["distill_#{key}"], "distill_#{key}")
        out[key] = v unless v.nil?
      end
      out
    end

    # the gated harvest. Same shape discipline as distill; the
    # negative list is a JSON array of { rule, pattern, note }.
    def harvest_patch(r)
      enabled = r.params["harvest_enabled"] == "1"
      out = { "enabled" => enabled }
      (p = presence(r.params["harvest_prompt"])) && (out["prompt"] = p)
      %w[idle_hours min_messages].each do |key|
        v = edge_int(r.params["harvest_#{key}"], "harvest_#{key}")
        out[key] = v unless v.nil?
      end
      negative = json_block(r.params["harvest_negative_list"], "harvest negative_list")
      out["negative_list"] = negative unless negative.nil?
      miner = harvest_miner_patch(r)
      out["miner"] = miner unless miner.empty?
      out
    end

    def harvest_miner_patch(r)
      miner = {}
      (m = presence(r.params["harvest_miner_model"])) && (miner["model"] = m)
      window = {}
      (w = edge_int(r.params["harvest_miner_window"], "harvest_miner_window")) && (window["last_sessions"] = w)
      miner["window"] = window unless window.empty?
      (m = edge_int(r.params["harvest_miner_max_proposals"], "harvest_miner_max_proposals")) && (miner["max_proposals"] = m)
      budget = {}
      (t = edge_int(r.params["harvest_miner_budget_tokens"], "harvest_miner_budget_tokens")) && (budget["tokens"] = t)
      miner["budget"] = budget unless budget.empty?
      miner
    end

    # Refinement: mode select + the report/propose/auto_apply knobs. Blank
    # mode = report-only (the no-opt-in default — the form's "report" option
    # writes it down explicitly).
    def refinement_patch(r)
      mode = presence(r.params["refinement_mode"])
      out = { "mode" => mode } if mode
      (w = edge_int(r.params["refinement_window"], "refinement_window")) && (out["window"] = { "last_sessions" => w })
      (f = edge_int(r.params["refinement_max_findings"], "refinement_max_findings")) && (out["max_findings"] = f)
      files = list(r.params["refinement_files"])
      out["files"] = files unless files.empty?
      proposers = list(r.params["refinement_proposers"])
      out["proposers"] = proposers unless proposers.empty?
      (t = edge_int(r.params["refinement_budget_tokens"], "refinement_budget_tokens")) && (out["budget"] = { "tokens" => t })
      (e = edge_int(r.params["refinement_auto_apply_max_edits"], "refinement_auto_apply_max_edits")) && (out["auto_apply_max_edits"] = e)
      out
    end

    # WS2: the calendar spend caps. All blank = no budget (parity).
    def budget_patch(r)
      daily = edge_int(r.params["budget_daily"], "budget_daily")
      monthly = edge_int(r.params["budget_monthly"], "budget_monthly")
      return nil if daily.nil? && monthly.nil?

      out = {}
      out["daily"] = daily unless daily.nil?
      out["monthly"] = monthly unless monthly.nil?
      (a = edge_float(r.params["budget_alert_at"], "budget_alert_at")) && (out["alert_at"] = a)
      out["soft"] = r.params["budget_soft"] == "1"
      out
    end

    # WS3: retries/backoff/fallback/breaker/timeout. All blank = the plain
    # single attempt (parity).
    def reliability_patch(r)
      retries = edge_int(r.params["reliability_retries"], "reliability_retries")
      backoff = presence(r.params["reliability_backoff"])
      timeout = edge_int(r.params["reliability_timeout"], "reliability_timeout")
      fallback = list(r.params["reliability_fallback"])
      return nil if retries.nil? && backoff.nil? && timeout.nil? && fallback.empty?

      out = {}
      out["retries"] = retries unless retries.nil?
      out["backoff"] = backoff if backoff
      out["timeout"] = timeout unless timeout.nil?
      out["fallback"] = fallback unless fallback.empty?
      breaker = {}
      %w[after within cooldown].each do |key|
        v = edge_int(r.params["reliability_breaker_#{key}"], "reliability_breaker_#{key}")
        breaker[key] = v unless v.nil?
      end
      out["circuit_breaker"] = breaker unless breaker.empty?
      out
    end

    # WS6: the operator-alert webhook. Blank = no webhook (parity).
    def alerts_patch(r)
      url = presence(r.params["alerts_webhook"])
      url ? { "webhook" => url } : nil
    end

    # Which internal channels may cross to the customer. Both checkboxes are
    # rendered, so the patch reflects the whole state (false = held back).
    def edge_stream_patch(r)
      { "thinking" => r.params["edge_thinking"] == "1",
        "intermediate" => r.params["edge_intermediate"] == "1" }
    end

    # skills_eager: blank = none (progressive disclosure, parity); "all" =
    # blanket eager; otherwise a comma list of exactly these.
    def skills_eager_patch(r)
      raw = r.params["skills_eager"].to_s.strip
      return nil if raw.empty?

      raw == "all" ? true : list(raw)
    end

    # A JSON textarea -> parsed Hash/Array, or nil when blank. Malformed JSON
    # is a ValidationError (a red flash, never a silent drop).
    def json_patch(r, field)
      json_block(r.params[field], field)
    end

    def json_block(raw, field)
      text = raw.to_s.strip
      return nil if text.empty?

      begin
        JSON.parse(text)
      rescue JSON::ParserError => e
        raise Insika::ValidationError, "#{field}: invalid JSON (#{e.message.lines.first.to_s.strip})"
      end
    end

    # A comma-separated list field. Blank = [] (none) — the explicit empty
    # reading; an allowlist-style field wants nil=all and should not use this.
    def list_patch(r, field)
      list(r.params[field])
    end

    # An ALLOWLIST-style field (nil = all, [] = none). Blank → nil (all), the
    # open reading; a typed list closes it to exactly those names.
    def allowlist_patch(r, field)
      names = list(r.params[field])
      names.empty? ? nil : names
    end

    def list(str)
      str.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?).uniq
    end

    # One non-blank token per line.
    def lines(str)
      str.to_s.lines.map(&:strip).reject(&:empty?)
    end

    # Guardrails config from the form. The config form OWNS the fields it
    # renders, so the patch reflects the whole rendered state. String values
    # round-trip cleanly through the JSON store; Safety::Config normalizes on
    # read. A blank moderator drops the key (deterministic only).
    #
    # `corpora` (the removability knob — languages/extra) has NO
    # form field: it is DSL/pack data (docs/domain.md), not Studio UI. The
    # form must not erase it on save — carry the existing value through
    # (the shallow patch merge would otherwise wipe it, the halt_when class).
    def guardrails_patch(r)
      out = {
        "input" => r.params["guardrail_input"] == "1",
        "output" => r.params["guardrail_output"] == "1",
        "strictness" => presence(r.params["guardrail_strictness"]) || "medium"
      }
      (mod = presence(r.params["guardrail_moderator"])) && (out["moderator"] = mod)
      responses = guardrail_responses_patch(r)
      out["responses"] = responses unless responses.empty?
      existing = @agent.guardrails || {}
      out["corpora"] = existing["corpora"] if existing["corpora"]
      out
    end

    # Per-category safe-reply overrides (config over convention). Only
    # the non-blank fields are persisted; Safety::Config normalizes on read.
    def guardrail_responses_patch(r)
      %w[default injection sexual abuse escalate].each_with_object({}) do |cat, acc|
        (v = presence(r.params["guardrail_response_#{cat}"])) && (acc[cat] = v)
      end
    end

    # Per-agent generation params. The config form OWNS these fields, so
    # the patch reflects the whole form state: a blank field drops the key (and an
    # all-blank form clears params to {}). temperature/max_tokens MUST be Numeric —
    # ModelSelection#apply_params guards on `numeric?` and silently skips a String —
    # so coerce here; a malformed number is dropped rather than 500-ing the save.
    # thinking is a reasoning-effort string (low/medium/high), applied verbatim.
    def params_patch(r)
      out = {}
      t = coerce(r.params["temperature"]) { |v| Float(v) }
      out["temperature"] = t unless t.nil?
      m = coerce(r.params["max_tokens"]) { |v| Integer(v) }
      out["max_tokens"] = m unless m.nil?
      thinking = presence(r.params["thinking"])
      out["thinking"] = thinking if thinking
      out
    end

    # Per-agent model fence: { "allow" => [refs] } where a ref is
    # "provider/model", "provider/*" or "model". Blank textarea -> nil (NO fence,
    # all models — parity). Enforced on the RESOLVED model by the ModelResolver,
    # so a per-chat pin can never escape it.
    def model_policy_patch(r)
      refs = split_list(r.params["model_policy_allow"])
      refs.empty? ? nil : { "allow" => refs }
    end

    # Parses a numeric-ish form field, returning nil for blank or unparseable input
    # (never raises — a bad value must not turn a config save into a 500).
    def coerce(raw)
      v = presence(raw)
      return nil unless v

      yield(v)
    rescue ArgumentError, TypeError
      nil
    end

    # Fields a tool CAN carry that this form does not render. The store REPLACES the
    # record on write, so anything missing here is erased — a save that only fixed a
    # typo in the description would silently drop them (the class of bug already
    # paid for once). `stored` carries them through untouched.
    UNEDITED_TOOL_FIELDS = %w[group tags halt_when].freeze

    # :write_data_tool payload from the form. nested request/response;
    # headers/query as "key=value" per line (same idiom as the MCP env —
    # a masked secret comes back as a sentinel and is reconciled in the store).
    # `stored` = the definition being edited (nil when creating).
    def tool_patch(r, stored = nil)
      preserved = (stored || {}).slice(*UNEDITED_TOOL_FIELDS).compact
      preserved.merge(
        name: presence(r.params["name"]),
        description: r.params["description"].to_s,
        parameters: parse_parameters(r.params["parameters"]),
        request: {
          method: presence(r.params["method"]) || "GET",
          url: r.params["url"].to_s,
          headers: parse_kv_lines(r.params["headers"]),
          query: parse_kv_lines(r.params["query"]),
          body: presence(r.params["body"])
        },
        response: {
          extract: presence(r.params["extract"]) || "body_raw",
          path: presence(r.params["path"])
        },
        secret_headers: split_list(r.params["secret_headers"]),
        timeout: presence(r.params["timeout"])
      )
    end

    # Parameters, TWO accepted syntaxes in one field (auto-detected, no mode toggle):
    # text starting with `{` is a full JSON Schema — the only form that expresses
    # nesting (an array of objects, a nested object); anything else is the flat
    # pipe-delimited sugar. This is what keeps the editor from being a lossy
    # round-trip: a nested tool renders as JSON here and saves back as the same JSON,
    # instead of being flattened into a shape its author never wrote.
    def parse_parameters(text)
      s = text.to_s.strip
      return parse_param_lines(text) unless s.start_with?("{")

      begin
        JSON.parse(s)
      rescue JSON::ParserError => e
        raise Insika::ValidationError, "parameters: invalid JSON Schema (#{e.message.lines.first.to_s.strip})"
      end
    end

    # Flat sugar: one line per param, pipe-delimited (CSP forbids JS for
    # dynamic lines; a textarea is the honest path, like the MCP env):
    #   name | type | required|optional | description
    def parse_param_lines(text)
      text.to_s.each_line.filter_map do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        name, type, req, desc = line.split("|", 4).map(&:strip)
        next if name.to_s.empty?

        { "name" => name, "type" => (presence(type) || "string"),
          "required" => req.to_s.downcase != "optional", "description" => desc.to_s }
      end
    end

    def settings_patch(r)
      patch = {
        "streaming" => r.params["streaming"] == "1"
      }
      { "request_timeout" => "request_timeout", "max_retries" => "max_retries",
        "turn_timeout" => "turn_timeout", "tool_timeout" => "tool_timeout" }.each_key do |f|
        v = presence(r.params[f])
        patch[f] = Integer(v) if v
      end
      # memory TTL (days). Blank = off (nil); a number sets the
      # platform default for EVERY cell. Saving here replaces an ops-authored
      # per-tenant map in the record — the view says so.
      v = presence(r.params["memory_ttl_days"])
      patch["memory_ttl_days"] = v.nil? ? nil : Integer(v)
      patch
    end

    # Edge limits — the platform rate-limit/cost layer, saved
    # from its OWN form (a sub-resource, like models). The limit fields write nil
    # when blank (off — the EdgeLimiter reads nil/0 as off); the windows fall back
    # to the built-in defaults when cleared (the limiter guards non-positive).
    def edge_patch(r)
      edge = {}
      %w[chat_rate_limit chat_rate_window agent_token_ceiling agent_token_window].each do |f|
        edge[f] = edge_int(r.params[f], f)
      end
      edge["limit_response"] = presence(r.params["limit_response"])
      { "edge" => edge }
    end

    # An eval case arrives as the YAML text the operator edited — the same shape the
    # corpus files hold, so there is one format to learn and a pull request can review
    # what was authored. Decoding happens HERE, at the transport edge; the SHAPE is
    # validated by the one loader inside the store, so both doors agree.
    def golden_patch(r)
      parsed = begin
        YAML.safe_load(r.params["yaml"].to_s, permitted_classes: [], aliases: false)
      rescue Psych::SyntaxError => e
        raise Insika::ValidationError, "invalid YAML: #{e.message}"
      end
      raise Insika::ValidationError, "the case must be a YAML mapping (id/agent/turns/expect)" unless parsed.is_a?(Hash)

      { case: parsed }
    end

    # Evals graders. `judges` is one `provider/model` per LINE — a
    # textarea, because the SIZE of the panel is the point and a fixed pair of fields
    # would cap it at two. A bare `model` (no slash) is valid: the provider is then
    # inferred by RubyLLM, same as everywhere else.
    def evals_patch(r)
      judges = r.params["judges"].to_s.lines.filter_map do |line|
        ref = presence(line)
        next unless ref

        provider, model = ref.include?("/") ? ref.split("/", 2) : [nil, ref]
        { "provider" => presence(provider), "model" => presence(model) }.compact
      end.reject { |j| j["model"].nil? }

      {
        "evals" => {
          "judges" => judges,
          "aggregate" => %w[median mean min].include?(r.params["aggregate"]) ? r.params["aggregate"] : "median",
          # Same strictness as the edge fields: a typo must not silently become "off"
          # (min_agreement 0 would pass a case no judge liked).
          "min_agreement" => edge_float(r.params["min_agreement"], "min_agreement"),
          "quorum" => edge_int(r.params["quorum"], "quorum"),
          "tolerance" => edge_float(r.params["tolerance"], "tolerance")
        }.compact
      }
    end

    # Strict float, blank = nil (inherit the default). Mirrors edge_int.
    def edge_float(raw, field)
      v = presence(raw)
      return nil unless v

      Float(v)
    rescue ArgumentError, TypeError
      raise Insika::ValidationError, "#{field} must be a number (got #{raw.inspect})"
    end

    # Strict integer for the edge fields: blank = nil (off / inherit — intentional),
    # but an UNPARSEABLE value must not silently disable a production limit (the
    # `coerce` drop-to-nil semantics would turn a typo into "off" with a green
    # flash). ValidationError -> with_flash renders it as the red flash, no dispatch.
    def edge_int(raw, field)
      v = presence(raw)
      return nil unless v

      Integer(v)
    rescue ArgumentError, TypeError
      raise Insika::ValidationError, "#{field} must be an integer (got #{raw.inspect})"
    end

    # LLM config v2 — the platform model layer, saved from its OWN form (a
    # sub-resource, like providers) so the general-settings save never touches it and
    # vice-versa. The scalar refs are always present (blank -> nil, which the
    # deep-merge writes and the ModelResolver reads as "no platform default");
    # fallback_models is a full-list replace (deep_merge substitutes arrays, so a
    # resubmit never accumulates).
    def model_defaults_patch(r)
      {
        "default_model" => presence(r.params["default_model"]),
        "default_provider" => presence(r.params["default_provider"]),
        "utility_model" => presence(r.params["utility_model"]),
        "fallback_models" => split_list(r.params["fallback_models"]),
        # GLOBAL reasoning default (4-layer). Blank -> nil = provider default.
        "thinking" => presence(r.params["thinking"])
      }
    end

    # Per-model reasoning defaults (the per-model layer). One line per model:
    #   <provider/model | model> | <off|on|low|medium|high>
    # CSP forbids JS for dynamic rows, so a textarea of lines is the honest path
    # (same idiom as the MCP env / tool params). A blank effort -> {} for that ref
    # (an inherit no-op). deep_merge merges per-ref, so refs accumulate; clearing an
    # override = set its effort blank (removing the ref entirely is a later refinement).
    def model_params_patch(r)
      map = r.params["model_params"].to_s.each_line.each_with_object({}) do |line, acc|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        ref, thinking = line.split("|", 2).map(&:strip)
        next if ref.to_s.empty?

        acc[ref] = { "thinking" => presence(thinking) }.compact
      end
      { "model_params" => map }
    end

    # LLM provider from the form. api_key is sentinel-aware: the form
    # pre-fills with the sentinel when a key already exists, so resubmitting
    # without touching preserves it; a new string replaces it; "" clears it. models = CSV.
    def provider_patch(r)
      {
        api: presence(r.params["api"]),
        base_url: r.params["base_url"].to_s,
        auth_header: r.params["auth_header"].to_s,
        api_key: r.params["api_key"].to_s,
        models: split_list(r.params["models"])
      }
    end

    # MCP instance from the form. `env` comes as "KEY=value" lines (CSP
    # forbids inline JS for add/remove line; a textarea is the simple, honest
    # path). Masked values come back as a sentinel — keeping them preserves
    # the secret; changing replaces; deleting the line clears it.
    def mcp_patch(r)
      {
        name: presence(r.params["name"]),
        transport: presence(r.params["transport"]) || "stdio",
        command: r.params["command"].to_s,
        url: r.params["url"].to_s,
        description: r.params["description"].to_s,
        enabled: r.params["enabled"] == "1",
        env: parse_kv_lines(r.params["env"])
      }
    end

    # "KEY=value" per line -> Hash. Ignores blank lines and comments (#).
    def parse_kv_lines(text)
      text.to_s.each_line.filter_map do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        k, v = line.split("=", 2)
        k = k.to_s.strip
        next if k.empty?

        [k, v.to_s.strip]
      end.to_h
    end
  end
end

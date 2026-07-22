# frozen_string_literal: true

module Studio
  # Form → command-payload parsing for the Studio App (§11 B6). A mixin, NOT a
  # standalone object: `include`d into App so every method keeps `self` == the
  # App instance and reaches its request helpers (`presence`, `split_list`) and
  # per-request state (`@agent`) exactly as before. Pure extraction — the bodies
  # moved verbatim from app.rb; app_spec's POST cases are the safety net.
  module Forms
    def config_patch(r)
      limits = @agent.limits.dup
      { "turn_timeout" => "turn_timeout", "tool_timeout" => "tool_timeout" }.each_key do |field|
        v = presence(r.params[field])
        limits[field.to_sym] = Integer(v) if v
      end
      # Per-agent edge overrides (item 33). Unlike the timeouts (always present via
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
        guardrails: guardrails_patch(r)
      }
    end

    # Guardrails config from the form (RFC-0009). The config form OWNS these fields,
    # so the patch reflects the whole guardrails state. String values round-trip
    # cleanly through the JSON store; Safety::Config normalizes on read. A blank
    # moderator drops the key (deterministic only).
    def guardrails_patch(r)
      out = {
        "input" => r.params["guardrail_input"] == "1",
        "output" => r.params["guardrail_output"] == "1",
        "strictness" => presence(r.params["guardrail_strictness"]) || "medium"
      }
      (mod = presence(r.params["guardrail_moderator"])) && (out["moderator"] = mod)
      responses = guardrail_responses_patch(r)
      out["responses"] = responses unless responses.empty?
      out
    end

    # Per-category safe-reply overrides (RFC-0009 §7, config over convention). Only
    # the non-blank fields are persisted; Safety::Config normalizes on read.
    def guardrail_responses_patch(r)
      %w[default injection sexual abuse escalate].each_with_object({}) do |cat, acc|
        (v = presence(r.params["guardrail_response_#{cat}"])) && (acc[cat] = v)
      end
    end

    # Per-agent generation params (v2, §10). The config form OWNS these fields, so
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

    # Per-agent model fence (v2, §10): { "allow" => [refs] } where a ref is
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

    # :write_data_tool payload from the form. nested request/response;
    # headers/query as "key=value" per line (same idiom as the MCP env —
    # a masked secret comes back as a sentinel and is reconciled in the store).
    def tool_patch(r)
      {
        name: presence(r.params["name"]),
        description: r.params["description"].to_s,
        parameters: parse_param_lines(r.params["parameters"]),
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
      }
    end

    # Parameters: one line per param, pipe-delimited (CSP forbids JS for
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
        "streaming" => r.params["streaming"] == "1",
        "compaction" => {
          "enabled" => r.params["compaction_enabled"] == "1"
        }
      }
      { "request_timeout" => "request_timeout", "max_retries" => "max_retries",
        "turn_timeout" => "turn_timeout", "tool_timeout" => "tool_timeout" }.each_key do |f|
        v = presence(r.params[f])
        patch[f] = Integer(v) if v
      end
      kl = presence(r.params["keep_last"])
      patch["compaction"]["keep_last"] = Integer(kl) if kl
      patch
    end

    # Edge limits (item 33 / §12 G7) — the platform rate-limit/cost layer, saved
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

    # Strict integer for the edge fields: blank = nil (off / inherit — intentional),
    # but an UNPARSEABLE value must not silently disable a production limit (the
    # `coerce` drop-to-nil semantics would turn a typo into "off" with a green
    # flash). ValidationError -> with_flash renders it as the red flash, no dispatch.
    def edge_int(raw, field)
      v = presence(raw)
      return nil unless v

      Integer(v)
    rescue ArgumentError, TypeError
      raise Harness::ValidationError, "#{field} must be an integer (got #{raw.inspect})"
    end

    # LLM config v2 (§10) — the platform model layer, saved from its OWN form (a
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
        "fallback_models" => split_list(r.params["fallback_models"])
      }
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

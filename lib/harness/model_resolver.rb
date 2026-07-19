# frozen_string_literal: true

module Harness
  # LLM config v2 resolution (FOLLOWUP §10). Turns the three config layers into a
  # single ModelSelection at turn start:
  #
  #   Chat (per-session pin) > Agent (profile.model) > Platform default (Settings)
  #
  # Also enforces the agent's `model_policy` on the RESOLVED model (a chat pin can
  # never escape the fence) and resolves the fallback chain + selection source.
  #
  # Pure: no ruby_llm, no store writes. `settings_store` is optional — nil means
  # "no platform layer" (an agent WITHOUT a model then fails high), preserving the
  # pre-v2 behavior for the many call sites that build an Executor without one.
  class ModelResolver
    # Reserved, collision-safe slot for the per-session model pin inside
    # `session.vars` (namespaced so it never renders in <request_context> — the
    # Request provider skips "__"-prefixed vars).
    SESSION_SLOT = "__llm__"

    def initialize(settings_store: nil)
      @settings_store = settings_store
    end

    # profile: AgentProfile; session: SessionStore::Session | nil.
    # -> ModelSelection. Raises PolicyDenied (model outside the agent's fence) or
    # Error (no model resolvable at any layer).
    def resolve(profile:, session: nil)
      settings = platform_settings
      model, provider, source, pinned = pick(profile, session, settings)

      if blank?(model)
        raise Harness::Error,
              "no model resolved for agent '#{profile.id}': set the agent model or a platform default_model (Settings)"
      end

      provider = provider&.to_sym
      enforce_policy!(profile, model, provider)

      ModelSelection.new(
        model: model, provider: provider, source: source, pinned: pinned,
        params: normalize_params(profile_params(profile)),
        fallbacks: pinned ? [] : resolve_fallbacks(profile, settings, model, provider)
      )
    end

    private

    # Chat pin > agent model > platform default. -> [model, provider, source, pinned].
    def pick(profile, session, settings)
      pin = session_pin(session)
      if pin && !blank?(pin[:model])
        [pin[:model], pin[:provider], :chat, true]
      elsif !blank?(profile.model)
        [profile.model, profile.provider, :agent, false]
      else
        [settings["default_model"], settings["default_provider"], :platform_default, false]
      end
    end

    # Per-session pin from vars["__llm__"] = { "model" =>, "provider" => }.
    # -> { model:, provider: } | nil (string keys — JSON round-trip).
    def session_pin(session)
      slot = session&.vars&.dig(SESSION_SLOT)
      return nil unless slot.is_a?(Hash)

      { model: slot["model"] || slot[:model], provider: slot["provider"] || slot[:provider] }
    end

    def enforce_policy!(profile, model, provider)
      policy = model_policy(profile)
      return if ModelPolicy.allowed?(policy, model: model, provider: provider)

      raise Harness::PolicyDenied.new(
        policy: :model_policy,
        reason: "model '#{ref(model, provider)}' not allowed for agent '#{profile.id}' " \
                "(allow: #{ModelPolicy.allow_list(policy).inspect})"
      )
    end

    # Platform fallback chain (Settings["fallback_models"]) minus the primary,
    # filtered by the agent's model_policy. Each entry: "provider/model" | "model".
    def resolve_fallbacks(profile, settings, primary_model, primary_provider)
      policy = model_policy(profile)
      Array(settings["fallback_models"]).filter_map do |entry|
        model, provider = parse_ref(entry)
        next if model.nil?
        next if model == primary_model && provider == primary_provider # dedupe the primary
        next unless ModelPolicy.allowed?(policy, model: model, provider: provider)

        { model: model, provider: provider }
      end
    end

    # "provider/model" -> [model, :provider]; "model" -> [model, nil].
    def parse_ref(entry)
      s = entry.to_s.strip
      return [nil, nil] if s.empty?

      if s.include?("/")
        provider, model = s.split("/", 2)
        [model, presence(provider)&.to_sym]
      else
        [s, nil]
      end
    end

    def platform_settings
      @settings_store ? @settings_store.get : {}
    end

    # `params` may be absent on legacy profiles (duck-typed). -> Hash.
    def profile_params(profile)
      profile.respond_to?(:params) ? (profile.params || {}) : {}
    end

    def model_policy(profile)
      profile.respond_to?(:model_policy) ? profile.model_policy : nil
    end

    # Coerces authored params (string|symbol keys from the JSON round-trip) into
    # the symbol shape ModelSelection#apply_params consumes.
    def normalize_params(params)
      out = {}
      params.each do |k, v|
        key = k.to_sym
        out[key] = v if %i[temperature max_tokens thinking].include?(key)
      end
      out
    end

    def ref(model, provider) = provider ? "#{provider}/#{model}" : model.to_s
    def blank?(v) = v.nil? || v.to_s.strip.empty?
    def presence(v) = blank?(v) ? nil : v.to_s
  end
end

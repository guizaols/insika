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

    # The layer that won resolution, before policy/fallback processing.
    # `source` is where the model came from (:chat/:agent/:platform_default).
    Choice = Data.define(:model, :provider, :source, :pinned)
    private_constant :Choice

    # profile: AgentProfile; session: SessionStore::Session | nil.
    # -> ModelSelection. Raises PolicyDenied (model outside the agent's fence) or
    # Error (no model resolvable at any layer).
    def resolve(profile:, session: nil)
      settings = platform_settings
      choice = pick(profile, session, settings)

      if blank?(choice.model)
        raise Harness::Error,
              "no model resolved for agent '#{profile.id}': set the agent model or a platform default_model (Settings)"
      end

      provider = choice.provider&.to_sym
      enforce_policy!(profile, choice.model, provider)

      ModelSelection.new(
        model: choice.model, provider: provider, source: choice.source, pinned: choice.pinned,
        params: normalize_params(profile_params(profile)),
        fallbacks: choice.pinned ? [] : resolve_fallbacks(profile, settings, choice.model, provider)
      )
    end

    private

    # Chat pin > agent model > platform default.
    def pick(profile, session, settings)
      pin = session_pin(session)
      if pin && !blank?(pin[:model])
        Choice.new(model: pin[:model], provider: pin[:provider], source: :chat, pinned: true)
      elsif !blank?(profile.model)
        Choice.new(model: profile.model, provider: profile.provider, source: :agent, pinned: false)
      else
        Choice.new(model: settings["default_model"], provider: settings["default_provider"],
                   source: :platform_default, pinned: false)
      end
    end

    # Per-session pin from vars["__llm__"] = { "model" =>, "provider" => }.
    # SessionStore deep_stringifies vars on write, so the slot is always
    # string-keyed. -> { model:, provider: } | nil.
    def session_pin(session)
      slot = session&.vars&.dig(SESSION_SLOT)
      return nil unless slot.is_a?(Hash)

      { model: slot["model"], provider: slot["provider"] }
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

    # AgentProfile always carries `params` (a string-keyed Hash, {} when unset)
    # and `model_policy` (nil = no fence) — no feature-detection needed.
    def profile_params(profile) = profile.params
    def model_policy(profile) = profile.model_policy

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
    def blank?(v) = Harness::Coercion.blank?(v)
    def presence(v) = Harness::Coercion.presence(v)
  end
end

# frozen_string_literal: true

module Insika
  # Governance of WHICH models an agent may use (`profile.model_policy`).
  # Cheap allowlist: exact refs + wildcard-by-provider — evaluated against the
  # RESOLVED (model, provider) at turn start (ModelResolver), so a chat override
  # can never pin a model outside the agent's fence.
  #
  # A ref is a String in one of three shapes:
  #   "provider/model"  -> matches that exact provider AND model
  #   "provider/*"      -> matches ANY model of that provider (wildcard)
  #   "model"           -> matches that model under ANY provider (provider-agnostic)
  #
  # `allow` semantics follow the ONE-allowlist rule of the project:
  #   nil = NO policy (every model allowed — parity, the common case)
  #   []  = NOTHING allowed (deny-all; an agent so configured cannot resolve a model)
  #   [refs] = the model must match at least one ref
  module ModelPolicy
    module_function

    # policy: `profile.model_policy` — a Hash `{ "allow" => [refs] }` | nil.
    # nil policy OR a nil/absent `allow` list = allowed (no fence). -> bool.
    def allowed?(policy, model:, provider:)
      allow = allow_list(policy)
      return true if allow.nil? # no fence

      model = model.to_s
      provider = provider.to_s
      allow.any? { |ref| match?(ref.to_s, model, provider) }
    end

    # Extracts the allow list (string|symbol key), nil when there is no fence.
    def allow_list(policy)
      return nil if policy.nil?

      list = policy["allow"] || policy[:allow]
      list.nil? ? nil : Array(list)
    end

    def match?(ref, model, provider)
      if ref.include?("/")
        ref_provider, ref_model = ref.split("/", 2)
        return false unless ref_provider == provider

        ref_model == "*" || ref_model == model
      else
        # provider-agnostic: match the model under any provider.
        ref == model
      end
    end
  end
end

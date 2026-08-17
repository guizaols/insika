# frozen_string_literal: true

module Insika
  # Source of AgentProfiles. Profiles used to be
  # a FROZEN Hash injected into the Executor and the turn Commands — static,
  # defined in Ruby at wiring time. For the Studio to create/edit agents at
  # runtime, the source needs to be MUTABLE and reloadable, without changing the
  # consumption contract.
  #
  # The consumption contract is minimal and duck-typed: `source[id] -> AgentProfile|nil`
  # (like a Hash). That's why the refactor in the Executor/Commands is just
  # normalizing the input (legacy Hash -> StaticProfileSource); the bodies that do
  # `@profiles[agent]` stay identical. `all`/`ids` are for the Studio to list.
  #
  # `nil` from `[]`/`fetch` = agent not configured (the Commands raise
  # NotFoundError) — NEVER raises (unlike Hash#fetch).
  module ProfileSource
    # Hash-compat sugar: `source[id]`.
    def [](id) = fetch(id)

    # Normalizes the consumers' input: a legacy Hash becomes a StaticProfileSource;
    # a ProfileSource passes straight through. A single place for the compat seam.
    def self.coerce(profiles)
      return profiles if profiles.is_a?(ProfileSource)

      StaticProfileSource.new(profiles || {})
    end

    # subclasses implement: fetch(id) -> AgentProfile|nil, all -> [AgentProfile], ids -> [String]
  end

  # Static source (parity): wraps the usual {id => AgentProfile} Hash.
  # Behavior IDENTICAL to the frozen Hash — zero regression.
  class StaticProfileSource
    include ProfileSource

    def initialize(profiles = {})
      @profiles = profiles
    end

    def fetch(id) = @profiles[id]
    def all = @profiles.values
    def ids = @profiles.keys
  end

  # Persisted source (Studio): reads/writes profiles in the ConfigStore (scope "agents").
  # Each `fetch` reads FRESH from the store — an edit via the Studio takes effect on
  # the next dispatch, without a restart. An in-flight turn keeps the profile it
  # captured (the Commands resolve at the start of #call), so the turn semantics are
  # preserved.
  class StoredProfileSource
    include ProfileSource
    include Coercion

    SCOPE = "agents"

    def initialize(config_store:)
      @cs = config_store
    end

    def fetch(id)
      record = @cs.get(SCOPE, id.to_s)
      record && deserialize(record)
    end

    def all = @cs.all(SCOPE).map { |r| deserialize(r) }
    def ids = @cs.keys(SCOPE)

    # Write (used by the :create_agent/:update_agent Commands).
    def put(profile)
      @cs.put(SCOPE, profile.id, profile.to_h)
      profile
    end

    def delete(id) = @cs.delete(SCOPE, id.to_s)

    private

    # Rebuilds the AgentProfile from the record (the JSON round-trip turns symbols
    # into strings). Re-symbolizes the fields the runtime consumes as symbols:
    # provider, policies (names in the PolicyRegistry) and the limits keys (
    # DEFAULT_LIMITS uses symbols and the merge would break with string keys).
    def deserialize(record)
      h = symbolize_top(record)
      AgentProfile.build(
        id: h[:id], model: h[:model],
        provider: presence(h[:provider])&.to_sym,
        base_prompt: h[:base_prompt].to_s,
        prompt_files: h[:prompt_files] || [],
        tools_allow: h[:tools_allow], tools_deny: h[:tools_deny] || [],
        tools_allow_groups: h[:tools_allow_groups],
        skills: h[:skills],
        skills_eager: h[:skills_eager],
        context_providers: h[:context_providers],
        workflows_allow: h[:workflows_allow],
        policies: Array(h[:policies]).map(&:to_sym),
        prompt_refs: h[:prompt_refs] || [],
        limits: symbolize_limits(h[:limits]),
        approvals_required: h[:approvals_required],
        capabilities: h[:capabilities],
        # subagents: allowlist of child ids; build re-normalizes to
        # [String]. nil round-trips as nil (opt-in: NONE).
        subagents: h[:subagents],
        tools_deferred: h[:tools_deferred],
        memory: h[:memory],
        prompt_caching: h[:prompt_caching],
        tool_output_compression: h[:tool_output_compression],
        # params/model_policy: the resolver tolerates string keys from
        # the JSON round-trip (ModelResolver#normalize_params / ModelPolicy), so no
        # re-symbolization needed here.
        params: h[:params] || {},
        model_policy: h[:model_policy],
        budget: h[:budget],
        reliability: h[:reliability],
        alerts: h[:alerts],
        routes: h[:routes],
        stuck_signal: h[:stuck_signal],
        outputs: h[:outputs],
        briefing_fields: h[:briefing_fields],
        # RFC-0029: grounding profile data — a plain Hash read with string keys
        # by Insika::Grounding.parse per turn; nil round-trips as nil (= off).
        grounding: h[:grounding],
        # guardrails: a plain Hash; Safety::Config tolerates the JSON
        # round-trip (string keys/values), so no re-symbolization here.
        guardrails: h[:guardrails],
        # sandbox: a plain config Hash; Sandbox.build tolerates the JSON
        # round-trip (string keys), so no re-symbolization here. nil = absent.
        sandbox: h[:sandbox],
        # refinement: a plain config Hash read with string keys by the
        # RunRefinement handler; nil round-trips as nil (= report-only).
        refinement: h[:refinement],
        # capabilities_declared: flat [String]; build re-normalizes.
        capabilities_declared: h[:capabilities_declared],
        # edge_stream: which internal channels may cross to the customer. {} = neither.
        edge_stream: h[:edge_stream],
        metadata: h[:metadata] || {},
        # RFC-0032: funnel declaration — a plain Hash read with string keys by
        # FunnelDeclaration.parse; nil round-trips as nil (= no funnel).
        funnel: h[:funnel],
        # RFC-0033: followup declaration — a plain Hash read with string keys by
        # FollowupPolicy.parse; nil round-trips as nil (= feature off).
        followup: h[:followup]
      )
    end

    def symbolize_top(record) = record.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }

    # limits keys -> symbol; numeric values preserved by JSON.
    def symbolize_limits(limits)
      return {} if limits.nil?

      limits.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end
  end
end

# frozen_string_literal: true

module Insika
  module Commands
    # Shared normalization for the agent-authoring payload.
    # The transport delivers string keys (JSON); internal dispatch uses
    # symbols. Here: symbolize the top level, keep only the fields buildable by
    # AgentProfile, and re-symbolize the fields the runtime consumes as symbols
    # (provider, policies, limits keys) — same rule as StoredProfileSource.
    module AgentPayload
      # Fields accepted by AgentProfile.build (order irrelevant).
      FIELDS = %i[id model provider base_prompt prompt_files tools_allow tools_deny
                  tools_allow_groups skills context_providers workflows_allow policies
                  prompt_refs limits approvals_required capabilities subagents tools_deferred
                  memory params model_policy guardrails metadata].freeze

      module_function

      # payload (string|symbol keys) -> Hash of attrs ready for AgentProfile.build.
      def attrs(payload)
        h = symbolize(payload)
        out = {}
        FIELDS.each { |f| out[f] = h[f] if h.key?(f) }
        out[:provider] = presence(out[:provider])&.to_sym if out.key?(:provider)
        out[:policies] = Array(out[:policies]).map(&:to_sym) if out.key?(:policies)
        out[:limits] = out[:limits].transform_keys(&:to_sym) if out[:limits].is_a?(Hash)
        # generation params (v2, §10) consumed by symbol key (temperature/max_tokens/thinking).
        out[:params] = out[:params].transform_keys(&:to_sym) if out[:params].is_a?(Hash)
        out
      end

      def symbolize(payload)
        (payload || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      # Stable name used by the handlers; the rule lives in Insika::Coercion.
      def presence(str) = Insika::Coercion.presence(str)
    end
  end
end

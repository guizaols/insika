# frozen_string_literal: true

module Harness
  module Commands
    # Normalização compartilhada do payload de autoria de agente.
    # O transporte entrega chaves string (JSON); o dispatch interno usa
    # symbol. Aqui: symboliza o topo, filtra só os campos construíveis do
    # AgentProfile, e re-simboliza os campos que o runtime consome como symbol
    # (provider, policies, chaves de limits) — mesma regra do StoredProfileSource.
    module AgentPayload
      # Campos aceitos por AgentProfile.build (ordem irrelevante).
      FIELDS = %i[id model provider base_prompt prompt_files tools_allow tools_deny
                  skills context_providers workflows_allow policies prompt_refs
                  limits approvals_required capabilities tools_deferred memory
                  metadata].freeze

      module_function

      # payload (string|symbol keys) -> Hash de attrs prontos p/ AgentProfile.build.
      def attrs(payload)
        h = symbolize(payload)
        out = {}
        FIELDS.each { |f| out[f] = h[f] if h.key?(f) }
        out[:provider] = presence(out[:provider])&.to_sym if out.key?(:provider)
        out[:policies] = Array(out[:policies]).map(&:to_sym) if out.key?(:policies)
        out[:limits] = out[:limits].transform_keys(&:to_sym) if out[:limits].is_a?(Hash)
        out
      end

      def symbolize(payload)
        (payload || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      # Nome estável usado pelos handlers; a regra mora em Harness::Coercion.
      def presence(str) = Harness::Coercion.presence(str)
    end
  end
end

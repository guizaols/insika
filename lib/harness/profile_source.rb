# frozen_string_literal: true

module Harness
  # Fonte de AgentProfiles. Antes os profiles eram
  # um Hash CONGELADO injetado no Executor e nos Commands de turno — estáticos,
  # definidos em Ruby no wiring. Para o Studio criar/editar agentes em runtime,
  # a fonte precisa ser MUTÁVEL e recarregável, sem mudar o contrato de consumo.
  #
  # O contrato de consumo é mínimo e duck-typed: `source[id] -> AgentProfile|nil`
  # (igual a um Hash). Por isso o refactor no Executor/Commands é só normalizar a
  # entrada (Hash legado -> StaticProfileSource); os corpos que fazem
  # `@profiles[agent]` seguem idênticos. `all`/`ids` são para o Studio listar.
  #
  # `nil` em `[]`/`fetch` = agente não configurado (os Commands levantam
  # NotFoundError) — NUNCA levanta (diferente de Hash#fetch).
  module ProfileSource
    # Açúcar de compat com o Hash: `source[id]`.
    def [](id) = fetch(id)

    # Normaliza a entrada dos consumidores: Hash legado vira StaticProfileSource;
    # um ProfileSource passa direto. Um lugar só para a costura de compat.
    def self.coerce(profiles)
      return profiles if profiles.is_a?(ProfileSource)

      StaticProfileSource.new(profiles || {})
    end

    # subclasses implementam: fetch(id) -> AgentProfile|nil, all -> [AgentProfile], ids -> [String]
  end

  # Fonte estática (paridade): envolve o Hash {id => AgentProfile} de
  # sempre. Comportamento IDÊNTICO ao Hash congelado — zero regressão.
  class StaticProfileSource
    include ProfileSource

    def initialize(profiles = {})
      @profiles = profiles
    end

    def fetch(id) = @profiles[id]
    def all = @profiles.values
    def ids = @profiles.keys
  end

  # Fonte persistida (Studio): lê/grava profiles no ConfigStore (scope "agents").
  # Cada `fetch` lê FRESCO do store — uma edição pelo Studio vale no próximo
  # dispatch, sem restart. Um turno em andamento mantém o profile que capturou
  # (os Commands resolvem no início do #call), então a semântica do turno é
  # preservada.
  class StoredProfileSource
    include ProfileSource

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

    # Escrita (usada pelos Commands :create_agent/:update_agent).
    def put(profile)
      @cs.put(SCOPE, profile.id, profile.to_h)
      profile
    end

    def delete(id) = @cs.delete(SCOPE, id.to_s)

    private

    # Reconstrói o AgentProfile a partir do record (JSON round-trip torna symbol
    # em string). Re-simboliza os campos que o runtime consome como symbol:
    # provider, policies (nomes no PolicyRegistry) e as chaves de limits (o
    # DEFAULT_LIMITS usa symbol e o merge quebraria com chaves string).
    def deserialize(record)
      h = symbolize_top(record)
      AgentProfile.build(
        id: h[:id], model: h[:model],
        provider: presence(h[:provider])&.to_sym,
        base_prompt: h[:base_prompt].to_s,
        prompt_files: h[:prompt_files] || [],
        tools_allow: h[:tools_allow], tools_deny: h[:tools_deny] || [],
        skills: h[:skills],
        context_providers: h[:context_providers],
        workflows_allow: h[:workflows_allow],
        policies: Array(h[:policies]).map(&:to_sym),
        prompt_refs: h[:prompt_refs] || [],
        limits: symbolize_limits(h[:limits]),
        approvals_required: h[:approvals_required],
        capabilities: h[:capabilities],
        tools_deferred: h[:tools_deferred],
        memory: h[:memory]
      )
    end

    def symbolize_top(record) = record.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }

    # Chaves de limits -> symbol; valores numéricos preservados pelo JSON.
    def symbolize_limits(limits)
      return {} if limits.nil?

      limits.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end

    def presence(str) = (s = str.to_s).empty? ? nil : s
  end
end

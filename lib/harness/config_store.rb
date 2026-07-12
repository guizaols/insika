# frozen_string_literal: true

require "time"

module Harness
  # Store de DOMÍNIO de CONFIGURAÇÃO (Fase 4 — Studio, D2/D5). Diferente dos
  # stores de EXECUÇÃO (session/task/checkpoint/pending/memory), este guarda a
  # configuração que o Studio autora em runtime: agentes (profiles), settings
  # gerais, providers de LLM e instâncias MCP. KV escopado sobre um
  # `Harness::Store` qualquer — durável quando o backend é SQLite (sobrevive a
  # restart, como o resto).
  #
  # scope lógico -> namespace físico "config:<scope>". Valores são Hashes
  # JSON-serializáveis (symbol vira string no round-trip, como o contrato do
  # Store; o domínio re-simboliza na borda — ver StoredProfileSource).
  class ConfigStore
    SCOPE_PREFIX = "config"
    # agent_files/skills entram na Etapa C (D3 revisado): o CONTEÚDO de prompts
    # por-agente e de skills compartilhadas vive no Store (fonte da verdade única,
    # um SQLite de backup), não em disco — disco vira só seed/import.
    SCOPES = %w[agents settings llm_providers mcp agent_files skills].freeze

    class UnknownScope < Harness::Error; end

    def initialize(store:)
      @store = store
    end

    # Upsert (last-write-wins). -> value (o mesmo Hash passado)
    def put(scope, key, value)
      @store.set(ns(scope), key.to_s, stringify(value))
      value
    end

    # -> Hash | nil
    def get(scope, key)
      @store.get(ns(scope), key.to_s)
    end

    # -> bool (existia?)
    def delete(scope, key)
      @store.delete(ns(scope), key.to_s)
    end

    # -> [String] chaves do scope, ordenadas lexicograficamente
    def keys(scope)
      @store.list(ns(scope))
    end

    # -> [Hash] todos os records do scope (ordem lexicográfica das chaves)
    def all(scope)
      s = ns(scope)
      @store.list(s).filter_map { |k| @store.get(s, k) }
    end

    private

    def ns(scope)
      key = scope.to_s
      raise UnknownScope, "scope de config desconhecido: #{scope.inspect}" unless SCOPES.include?(key)

      "#{SCOPE_PREFIX}:#{key}"
    end

    # Normaliza symbol->string ANTES de gravar (espelha MemoryStore#stringify):
    # o backend serializa JSON, e ler de volta traria strings de qualquer forma;
    # normalizar na escrita mantém o record consistente entre backends.
    def stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      when Symbol then obj.to_s
      else obj
      end
    end
  end
end

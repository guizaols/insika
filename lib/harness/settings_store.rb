# frozen_string_literal: true

module Harness
  # Settings GERAIS do deploy (Fase 4 — Studio, D6): timeouts, streaming e
  # compaction. Um único record no ConfigStore (scope "settings", key "general").
  # Leitura sempre devolve os DEFAULTS sobrepostos pelo que foi autorado — então
  # um deploy novo (store vazio) já responde com config coerente, e o Studio só
  # persiste o delta. Merge raso no topo, profundo em `compaction` (sub-hash).
  #
  # Não confundir com o `CONFIG` de transporte (bind/port/token, ENV+freeze no
  # boot): isto é config de RUNTIME editável, durável no mesmo backend.
  class SettingsStore
    SCOPE = "settings"
    KEY   = "general"

    DEFAULTS = {
      "streaming" => true,
      "request_timeout" => 120,
      "max_retries" => 2,
      "turn_timeout" => 120,
      "tool_timeout" => 30,
      "compaction" => { "enabled" => false, "keep_last" => 20 }
    }.freeze

    def initialize(config_store:)
      @cs = config_store
    end

    # -> Hash (defaults sobrepostos pelo autorado). Chaves string (contrato Store).
    def get
      deep_merge(DEFAULTS, stored)
    end

    # Merge do patch sobre o atual e persiste. -> Hash (settings resultante).
    # Chaves desconhecidas são preservadas (o Studio decide o schema da tela).
    def update(patch)
      merged = deep_merge(get, stringify(patch || {}))
      @cs.put(SCOPE, KEY, merged)
      merged
    end

    private

    def stored
      @cs.get(SCOPE, KEY) || {}
    end

    def deep_merge(base, override)
      base.merge(override) do |_key, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
      end
    end

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

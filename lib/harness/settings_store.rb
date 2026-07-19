# frozen_string_literal: true

module Harness
  # GENERAL deploy settings: timeouts, streaming and
  # compaction. A single record in the ConfigStore (scope "settings", key "general").
  # A read always returns the DEFAULTS overlaid by whatever was authored — so
  # a brand-new deploy (empty store) already responds with coherent config, and the Studio
  # only persists the delta. Shallow merge at the top, deep in `compaction` (sub-hash).
  #
  # Not to be confused with the transport `CONFIG` (bind/port/token, ENV+freeze at
  # boot): this is editable RUNTIME config, durable in the same backend.
  class SettingsStore
    SCOPE = "settings"
    KEY   = "general"

    DEFAULTS = {
      "streaming" => true,
      "request_timeout" => 120,
      "max_retries" => 2,
      "turn_timeout" => 120,
      "tool_timeout" => 30,
      "compaction" => { "enabled" => false, "keep_last" => 20 },
      # LLM config v2 (§10). Platform-wide model layer, resolved by the
      # ModelResolver under an agent that pins no model of its own:
      #   default_model/default_provider -> the platform default (Chat > Agent > HERE)
      #   fallback_models -> ordered chain ["provider/model" | "model", ...] tried
      #                      when the primary is NOT a user pin (source semantics)
      #   utility_model   -> slot for cheap internal tasks (titles, distillation,
      #                      compaction); reserved for later wiring.
      "default_model" => nil,
      "default_provider" => nil,
      "fallback_models" => [],
      "utility_model" => nil
    }.freeze

    def initialize(config_store:)
      @cs = config_store
    end

    # -> Hash (defaults overlaid by the authored values). String keys (Store contract).
    def get
      deep_merge(DEFAULTS, stored)
    end

    # Merges the patch over the current one and persists. -> Hash (resulting settings).
    # Unknown keys are preserved (the Studio decides the screen's schema).
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

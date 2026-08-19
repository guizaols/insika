# frozen_string_literal: true

module Insika
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

    # STRICT config, settings layer (— "no silent config compat: every
    # schema migration explicit"). The settings record carries a `schema_version`;
    # every shape change is a numbered migration here, applied ONLY by the explicit
    # `migrate!` (Studio settings saves never silently reinterpret old-shaped data).
    # v1 is the baseline: a pre-versioning record (no `schema_version`) reads as 0 and
    # `insika doctor --fix` stamps it to 1. Add a real change as MIGRATIONS[2] = proc
    # and bump SCHEMA_VERSION.
    SCHEMA_VERSION = 1
    MIGRATIONS = {}.freeze # target_version(Integer) => ->(record_hash){ migrated_hash }

    DEFAULTS = {
      "schema_version" => SCHEMA_VERSION,
      "streaming" => true,
      "request_timeout" => 120,
      "max_retries" => 2,
      "turn_timeout" => 120,
      "tool_timeout" => 30,
      "compaction" => { "enabled" => false, "keep_last" => 20 },
      # Data lifecycle (WS8, phase 2): the RETENTION window in days. The
      # tick's Retention sweep purges sessions (+traces), terminal tasks
      # (+checkpoints), memory cells and outcomes older than this. nil/0 =
      # OFF (parity — nothing is ever swept by default).
      "retention_days" => nil,
      # memory TTL. Integer = default for every cell; Hash =
      # per-tenant { "<tenant>" => days, "*" => days } (ops-authored). nil = OFF.
      # Swept by the Retention tick on its OWN daily claim, NOT gated by
      # retention_days (D5). Additive key — reads overlay DEFAULTS.
      "memory_ttl_days" => nil,
      # LLM config v2. Platform-wide model layer, resolved by the
      # ModelResolver under an agent that pins no model of its own:
      #   default_model/default_provider -> the platform default (Chat > Agent > HERE)
      #   fallback_models -> ordered chain ["provider/model" | "model", ...] tried
      #                      when the primary is NOT a user pin (source semantics)
      #   utility_model   -> slot for cheap internal tasks (titles, distillation,
      #                      compaction); reserved for later wiring.
      "default_model" => nil,
      "default_provider" => nil,
      "fallback_models" => [],
      "utility_model" => nil,
      # Reasoning control (4-layer: Chat > Agent > Model > Global). `thinking`
      # is the GLOBAL default (off/on/low/medium/high; nil = provider default);
      # `model_params` is the PER-MODEL layer, a map "<provider/model>"|"<model>" ->
      # { "thinking" => ... }. Both resolved by the ModelResolver.
      "thinking" => nil,
      "model_params" => {},
      # Evals (panel by). The GRADERS are platform config, so
      # the operator picks them in the Studio instead of remembering a CLI flag:
      #   judges        -> [{ "model" =>, "provider" => }, …]. [] = deterministic
      #                    asserts only (rubric'd cases read as judge_pending).
      #   aggregate     -> median | mean | min — how the panel's scores become the one
      #                    the report and the baseline read.
      #   min_agreement -> fraction of judges that must pass for the case to pass.
      #   quorum        -> samples per judge (variance), on top of the panel.
      #   tolerance     -> max judge-score drop before it counts as a regression.
      # Additive key: reads overlay DEFAULTS, so no numbered migration is due (only a
      # later SHAPE change to this key would earn one).
      "evals" => {
        "judges" => [],
        "aggregate" => "median",
        "min_agreement" => 0.5,
        "quorum" => 1,
        "tolerance" => 0.05
      },
      # Edge limits — the platform layer of the EdgeLimiter.
      # nil/0 = off (opt-in). chat_rate_limit = turn attempts per chat per
      # chat_rate_window (s); agent_token_ceiling = total tokens per agent per
      # agent_token_window (s). limit_response overrides the safe reply.
      # Per-agent overrides live in profile.limits (same keys, sans windows).
      "edge" => {
        "chat_rate_limit" => nil,
        "chat_rate_window" => 60,
        "agent_token_ceiling" => nil,
        "agent_token_window" => 86_400,
        "limit_response" => nil
      }
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

    # RAW persisted schema version (bypasses the DEFAULTS overlay, which would always
    # report the current one). nil = no settings persisted yet (fresh deploy — nothing
    # to migrate); an Integer otherwise, 0 for a pre-versioning record.
    def stored_schema_version
      raw = stored
      return nil if raw.empty?

      Integer(raw["schema_version"] || 0)
    end

    # Which numbered migrations still need to run. [] when fresh or already current.
    def pending_migrations
      from = stored_schema_version
      return [] if from.nil? || from >= SCHEMA_VERSION

      ((from + 1)..SCHEMA_VERSION).to_a
    end

    # Applies the pending migrations EXPLICITLY (in order) and stamps the version. No-op
    # when fresh or already current. -> resulting schema_version (Integer).
    def migrate!
      data = stored
      return SCHEMA_VERSION if data.empty?

      pending_migrations.each do |version|
        migration = MIGRATIONS[version]
        data = stringify(migration.call(data)) if migration
      end
      data["schema_version"] = SCHEMA_VERSION
      @cs.put(SCOPE, KEY, data)
      SCHEMA_VERSION
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

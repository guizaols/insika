# frozen_string_literal: true

module Insika
  # STRICT config, environment layer (item 23 / §8.1). OpenClaw's config discipline
  # — "recusa boot com chave desconhecida, no silent config compat" — applied to the
  # env vars the engine reads at boot. A declarative registry of the keys the engine
  # OWNS (config over convention: the schema IS data), used two ways:
  #
  #   · `validate(env)` — returns structured Findings: a value that fails its type
  #     (INSIKA_PORT=abc), an UNKNOWN key inside a namespace the engine owns
  #     (INSIKA_EGRES_ALLOW_HTTP — a typo the runtime would otherwise ignore in
  #     silence), and a DEPRECATED legacy key still set under the old HARNESS_ prefix.
  #     Unknown-key detection is scoped to the OWNED prefixes only, so the platform's
  #     own vars (Railway's RAILWAY_*, PORT, PATH, the litestream sidecar's
  #     LITESTREAM_*, the deployment's DEEPSEEK_*/CONSUMER_*) are never flagged.
  #   · `enforce!(strict:)` — the boot gate. WARNS on every finding by default and
  #     lets the engine come up (last-known-good — a rotated key or a typo must never
  #     take the whole service down, same reasoning as the resilient DEEPSEEK boot);
  #     RAISES ConfigError only when strictness is on (INSIKA_CONFIG_STRICT truthy,
  #     or `strict: true`).
  #
  # RENAME (env pass 2): the engine's owned prefix is now INSIKA_. The old HARNESS_
  # names still work — `reconcile_legacy!` backfills INSIKA_* from any HARNESS_* alias
  # at boot (new name wins), and `read` gives the same dual-read to the self-contained
  # readers (Telemetry, TurnTiming, SubagentGraph) that receive an env hash directly.
  # A legacy name in use surfaces as a `:deprecated` warning (never fatal) so operators
  # get a clear "rename to INSIKA_*" without a broken boot.
  #
  # Insika::Doctor reuses `validate` for its `env:*` checks; the boot roots call
  # `enforce!`. A deployment layers its own keys on via `extra:` (see
  # config/deployment.rb) so `insika env` and `insika doctor` see the full picture.
  module EnvSchema
    module_function

    # One env key the engine knows about. `type` drives validation; `secret` masks
    # the value in `insika env`; `enum` restricts allowed values; `required` makes
    # a blank value a finding (engine keys are all optional — deployment resilience —
    # so `required` is used by deployment extras, not the defaults here).
    Spec = Data.define(:name, :type, :secret, :required, :enum, :description) do
      def secret? = secret
      def required? = required

      # nil/blank when optional -> no finding. Present -> must satisfy the type. ->
      # error string or nil.
      def error_for(raw)
        value = raw.to_s
        return "is required (unset)" if value.strip.empty? && required
        return nil if value.strip.empty?

        case type
        when :integer
          "must be an integer, got #{value.inspect}" unless value.match?(/\A-?\d+\z/)
        when :boolean
          "must be a boolean (#{BOOLEANS.join('/')}), got #{value.inspect}" unless EnvSchema.boolean?(value)
        when :enum
          "must be one of #{enum.inspect}, got #{value.inspect}" unless Array(enum).include?(value)
        when :url
          "must be an http(s) URL, got #{value.inspect}" unless value.match?(%r{\Ahttps?://\S+\z})
        end # :string / :csv / :path -> any string is valid
      end
    end

    # A problem (or an :ok note) about the environment. dry/serializable — the proc-
    # free shape Doctor and `insika env` both render.
    Finding = Data.define(:key, :kind, :severity, :message) do
      def to_h = { "key" => key, "kind" => kind.to_s, "severity" => severity.to_s, "message" => message }
    end

    # The engine's owned prefix and its deprecated predecessor.
    PREFIX = "INSIKA_"
    LEGACY_PREFIX = "HARNESS_"

    # Prefixes the engine fully OWNS: an unknown key under one of these is a typo, not
    # a foreign var. INSIKA_ (current) and HARNESS_ (legacy, still honored during the
    # deprecation window). Deliberately NOT OPENCLAW_ (shared with the OpenClaw gateway
    # product, which sets its own OPENCLAW_HOME/_STATE_DIR/… — the engine merely borrows
    # 3 names for interop), nor LITESTREAM_ (the sidecar owns it), nor OTEL_ (the
    # OpenTelemetry SDK owns its env).
    OWNED_PREFIXES = [PREFIX, LEGACY_PREFIX].freeze

    BOOLEANS = %w[1 0 true false yes no on off].freeze

    def boolean?(value) = BOOLEANS.include?(value.to_s.strip.downcase)

    # Truthy per the engine's convention (telemetry/turn_timing agree). The single
    # home for "is this env flag on?".
    def truthy?(value) = %w[1 true yes on].include?(value.to_s.strip.downcase)

    def present?(value) = !value.nil? && !value.to_s.strip.empty?

    def spec(name:, type: :string, secret: false, required: false, enum: nil, description: "")
      Spec.new(name: name, type: type, secret: secret, required: required, enum: enum, description: description)
    end

    # The engine's own keys. Deployment/app keys (DEEPSEEK_*, CONSUMER_*, …) are NOT
    # here — a root passes them as `extra:`.
    DEFAULT = [
      spec(name: "INSIKA_DB", type: :path, description: "SQLite path; durable config+state. Unset -> ephemeral memory."),
      spec(name: "INSIKA_BIND", description: "Bind address for the transport server."),
      spec(name: "INSIKA_PORT", type: :integer, description: "Port for the transport server."),
      spec(name: "INSIKA_PUBLIC_URL", type: :url, description: "Public base URL (A2A agent card, links)."),
      spec(name: "INSIKA_ENV", description: "Environment name shown in the Studio (falls back to RACK_ENV)."),
      spec(name: "INSIKA_A2A_AGENT", description: "Agent id to expose over inbound A2A (opt-in)."),
      spec(name: "INSIKA_A2A_REMOTES", type: :csv, description: "Comma-separated remote A2A endpoints."),
      spec(name: "INSIKA_EGRESS_ALLOW_HTTP", type: :boolean, description: "Allow plain http egress from data-tools (default: https only)."),
      spec(name: "INSIKA_EGRESS_ALLOW_PRIVATE", type: :boolean, description: "Allow egress to private/loopback ranges (SSRF guard off)."),
      spec(name: "INSIKA_EGRESS_HOSTS", type: :csv, description: "Comma-separated host allowlist for data-tool egress."),
      spec(name: "INSIKA_OTEL", type: :boolean, description: "Turn on OpenTelemetry export (opt-in)."),
      spec(name: "INSIKA_MODEL_PRICING", description: "JSON rates table (USD per million tokens) for the estimated-cost attribute; unset -> no cost reported."),
      spec(name: "INSIKA_TURN_TIMING", type: :boolean, description: "Emit per-turn TTFB breakdown in responses (opt-in, item 34)."),
      spec(name: "INSIKA_SUBAGENT_DEPTH_CAP", type: :integer, description: "Max delegation depth in the subagent graph (default 5)."),
      spec(name: "INSIKA_SUBAGENT_FANOUT_CAP", type: :integer, description: "Max parallel children in spawn_subagents (default 8)."),
      spec(name: "INSIKA_CONFIG_STRICT", type: :boolean, description: "Refuse boot on any config finding instead of warning (item 23)."),
      spec(name: "INSIKA_BOOT_ID", description: "Boot generation id shared by all workers of one container start; the recovery task sweep runs once per id (RFC-0016). Unset -> every boot sweeps."),
      spec(name: "INSIKA_DRAIN_TIMEOUT", type: :integer, description: "Seconds a stopping worker waits for in-flight turns before abandoning them to the next boot's recovery (default 20, RFC-0016 A3)."),
      spec(name: "INSIKA_TICK_INTERVAL", type: :integer, description: "Seconds between tick passes (outbox drain + stale recovery sweep, RFC-0019). Default 60; 0 disables."),
      spec(name: "INSIKA_TICK_STALE_AFTER", type: :integer, description: "Seconds a :queued/:running task must sit untouched before the tick sweeps it (default 900, RFC-0019). Must exceed the largest turn_timeout of the deployment."),
      spec(name: "INSIKA_ONBOARDING", type: :boolean, description: "Expose the public onboarding surface (/start.md, /models.json, /docs) in production (opt-in, item 20)."),
      spec(name: "INSIKA_RELAY_TOKEN", secret: true, description: "Bearer the relay consumer sends us. Unset -> the relay channel is not mounted (RFC-0011 §6)."),
      spec(name: "INSIKA_RELAY_DELIVER_URL", type: :url, description: "Consumer callback the relay POSTs each reply to."),
      spec(name: "INSIKA_RELAY_DELIVER_TOKEN", secret: true, description: "Bearer the relay sends TO the consumer's callback (optional)."),
      spec(name: "INSIKA_WIDGET_ORIGINS", type: :csv, description: "Exact-match origins allowed to embed the web widget. Unset -> the widget channel is not mounted (RFC-0011 §5)."),
      spec(name: "INSIKA_WIDGET_AGENTS", type: :csv, description: "Agent ids a widget visitor may address. Unset -> the widget channel is not mounted."),
      spec(name: "OPENCLAW_GATEWAY_TOKEN", secret: true, description: "Bearer for /v1 + /a2a (falls back to ADMIN_TOKEN)."),
      spec(name: "OPENCLAW_AGENTS_DIR", type: :path, description: "Directory of OpenClaw-style agent packs."),
      spec(name: "OPENCLAW_PLUGIN_DIR", type: :path, description: "Directory of plugins to load."),
      spec(name: "ADMIN_TOKEN", secret: true, description: "Studio login token; unset -> /studio fail-closed."),
      spec(name: "OTEL_SERVICE_NAME", description: "Service name for OTEL spans (default: insika).")
    ].freeze

    # -- dual-read (rename compat) -------------------------------------

    # HARNESS_X -> INSIKA_X for the deprecated alias of a canonical key; nil if `name`
    # is not an INSIKA_ key.
    def legacy_alias(name)
      s = name.to_s
      s.start_with?(PREFIX) ? LEGACY_PREFIX + s[PREFIX.length..] : nil
    end

    # The current (canonical) name for any owned key: HARNESS_X -> INSIKA_X; an INSIKA_
    # key or any non-owned key is returned unchanged.
    def canonical(name)
      s = name.to_s
      s.start_with?(LEGACY_PREFIX) ? PREFIX + s[LEGACY_PREFIX.length..] : s
    end

    def legacy?(name) = name.to_s.start_with?(LEGACY_PREFIX)
    def owned?(name) = OWNED_PREFIXES.any? { |p| name.to_s.start_with?(p) }

    # Reads a canonical INSIKA_* key, falling back to the deprecated HARNESS_* alias
    # (new name wins). For the self-contained readers that get an env hash directly and
    # so never see `reconcile_legacy!`'s process-wide backfill. -> value | nil.
    def read(canonical_name, env = ENV)
      value = env[canonical_name]
      return value if present?(value)

      (legacy = legacy_alias(canonical_name)) ? env[legacy] : value
    end

    # BOOT backfill: copies every still-set HARNESS_* var to its INSIKA_* name (new name
    # wins if both are set) so the process ENV speaks the new names before any read.
    # Generic (not schema-bound) so plugin/deployment HARNESS_* keys migrate too. WARNS
    # once with the migrated list. -> [migrated legacy names]. Idempotent.
    def reconcile_legacy!(env = ENV, warn: method(:default_warn))
      migrated = env.keys.map(&:to_s).select { |k| k.start_with?(LEGACY_PREFIX) }.sort.each_with_object([]) do |legacy, acc|
        canonical = PREFIX + legacy[LEGACY_PREFIX.length..]
        next if present?(env[canonical]) # the new name already wins
        next if env[legacy].nil?

        env[canonical] = env[legacy]
        acc << legacy
      end
      unless migrated.empty?
        warn.call("deprecation: #{migrated.join(', ')} — HARNESS_* env vars are renamed to INSIKA_*; " \
                  "honored via the new names this run, please update your environment (legacy names removed in a future release)")
      end
      migrated
    end

    # -- validation ----------------------------------------------------

    # -> [Finding]. `extra` = deployment/app specs to fold into the known set (and to
    # widen unknown-key detection over their names). Never raises.
    def validate(env = ENV, extra: [])
      specs = index(DEFAULT + Array(extra))
      findings = []

      # VALUE + required checks over the KNOWN specs (owned or not — DEEPSEEK_API_KEY
      # is not prefixed). Dual-read: the canonical name wins, the legacy alias is honored.
      specs.each_value do |s|
        legacy = legacy_alias(s.name)
        set_name = if env.key?(s.name) then s.name
                   elsif legacy && env.key?(legacy) then legacy
                   end

        if set_name.nil?
          findings << Finding.new(key: s.name, kind: :missing_required, severity: :error,
                                  message: "#{s.name} is required (unset)") if s.required?
          next
        end

        msg = s.error_for(env[set_name])
        findings << Finding.new(key: set_name, kind: :invalid, severity: :error, message: "#{set_name} #{msg}") if msg
      end

      # OWNED-PREFIX scan: a legacy alias of a known key is DEPRECATED (warn); any other
      # owned key with no matching spec is UNKNOWN (a typo the runtime would ignore).
      env.each_key do |raw|
        key = raw.to_s
        next unless owned?(key)

        if legacy?(key) && specs.key?(canonical(key))
          findings << Finding.new(key: key, kind: :deprecated, severity: :warn,
                                  message: "#{key} is deprecated — rename to #{canonical(key)}")
        elsif !specs.key?(canonical(key)) && !specs.key?(key)
          findings << Finding.new(key: key, kind: :unknown, severity: :error,
                                  message: "#{key} is not a known config key (typo? unknown key in an owned namespace)")
        end
      end

      findings
    end

    # -> the specs the engine + a root know about (DEFAULT + extra), for `insika env`.
    def known_specs(extra: []) = (DEFAULT + Array(extra)).sort_by(&:name)

    # BOOT GATE. Validates the environment, WARNS every finding via `warn` (a callable
    # taking a String), and RAISES ConfigError only when strict. `strict` defaults to
    # the INSIKA_CONFIG_STRICT flag (HARNESS_CONFIG_STRICT still honored). -> [Finding]
    # (also on the happy path). The root keeps booting on warnings (last-known-good).
    def enforce!(env = ENV, extra: [], strict: nil, warn: method(:default_warn))
      strict = truthy?(read("INSIKA_CONFIG_STRICT", env)) if strict.nil?
      findings = validate(env, extra: extra)
      findings.each { |f| warn.call("config: #{f.message}") }

      errors = findings.select { |f| f.severity == :error }
      raise Insika::ConfigError.new("strict config check refused boot", findings: errors) if strict && errors.any?

      findings
    end

    def default_warn(message) = Kernel.warn("[config] #{message}")

    # -- internal ------------------------------------------------------

    def index(specs) = specs.each_with_object({}) { |s, acc| acc[s.name] = s }
  end
end

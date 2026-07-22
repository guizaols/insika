# frozen_string_literal: true

module Harness
  # `harness doctor` (item 23 / §8.1 — OpenClaw's "strict config + doctor --fix",
  # "the repo's best productization discipline"). A read-only diagnosis of a
  # deployment's configuration that turns the scattered, silent boot warnings into
  # ONE structured report — and, with `--fix`, applies the safe autofixes.
  #
  # Every check is DATA (config over convention): an id, a title, and a lambda that
  # inspects the injected collaborators and returns Findings. A Finding may carry a
  # `fix` proc; `fix!` runs those and re-diagnoses. Collaborators are optional so the
  # CLI can build them straight off the durable backend (no full app boot / no
  # DEEPSEEK) and an env-only caller can skip the store checks entirely.
  class Doctor
    # severity: :ok (green) | :info | :warn | :error. `fix` = a 0-arg proc or nil.
    Finding = Data.define(:check, :severity, :message, :fix) do
      def fixable? = !fix.nil?
      def ok? = severity == :ok
      def error? = severity == :error
      def to_h = { "check" => check, "severity" => severity.to_s, "message" => message, "fixable" => fixable? }
    end

    # The outcome of a run: the findings + convenience rollups + renderers.
    Report = Data.define(:findings) do
      def ok? = errors.empty?
      def errors   = findings.select(&:error?)
      def warnings = findings.select { |f| f.severity == :warn }
      def fixable  = findings.select(&:fixable?)

      def to_h
        { "ok" => ok?, "counts" => counts, "findings" => findings.map(&:to_h) }
      end

      def counts
        findings.each_with_object(Hash.new(0)) { |f, acc| acc[f.severity.to_s] += 1 }
      end

      # Human report. `color` wraps severities in ANSI when the sink is a TTY.
      def to_s(color: false)
        lines = findings.map { |f| "#{glyph(f.severity, color)} [#{f.check}] #{f.message}#{' (fixable)' if f.fixable?}" }
        summary =
          if ok? && warnings.empty? then "config OK"
          elsif ok? then "config OK — #{warnings.length} warning(s)"
          else "#{errors.length} error(s), #{warnings.length} warning(s)"
          end
        (lines + ["", summary]).join("\n")
      end

      private

      def glyph(severity, color)
        sym = { ok: "✓", info: "•", warn: "!", error: "✗" }.fetch(severity, "•")
        return sym unless color

        code = { ok: 32, info: 36, warn: 33, error: 31 }.fetch(severity, 0)
        "\e[#{code}m#{sym}\e[0m"
      end
    end

    def initialize(env: ENV, settings_store: nil, llm_provider_store: nil, backend: nil, extra_env_specs: [])
      @env = env
      @settings_store = settings_store
      @llm_provider_store = llm_provider_store
      @backend = backend
      @extra_env_specs = extra_env_specs
    end

    # -> Report. Never raises (a broken check degrades to an :error Finding).
    def run
      Report.new(findings: checks.flat_map { |check| safe(check) }.freeze)
    end

    # Applies every fixable finding, then re-diagnoses. -> [Report before, Report after].
    def fix!
      before = run
      before.fixable.map(&:fix).each(&:call)
      [before, run]
    end

    private

    def checks = %i[check_env check_settings_schema check_default_model check_db check_llm_provider check_admin_token]

    def safe(check)
      Array(send(check))
    rescue StandardError => e
      id = check.to_s.sub(/^check_/, "").tr("_", "-")
      [Finding.new(check: id, severity: :error, message: "check crashed: #{e.class}: #{e.message}", fix: nil)]
    end

    # -- checks --------------------------------------------------------

    def check_env
      findings = Harness::EnvSchema.validate(@env, extra: @extra_env_specs)
      return [ok("env", "environment: no unknown/invalid keys in owned namespaces")] if findings.empty?

      findings.map { |f| Finding.new(check: "env", severity: f.severity, message: f.message, fix: nil) }
    end

    def check_settings_schema
      return [] unless @settings_store

      pending = @settings_store.pending_migrations
      return [ok("settings-schema", "settings schema at v#{Harness::SettingsStore::SCHEMA_VERSION}")] if pending.empty?

      [Finding.new(check: "settings-schema", severity: :warn,
                   message: "settings schema at v#{@settings_store.stored_schema_version}, pending migration(s) #{pending.inspect} to v#{Harness::SettingsStore::SCHEMA_VERSION}",
                   fix: -> { @settings_store.migrate! })]
    end

    def check_default_model
      return [] unless @settings_store

      settings = @settings_store.get
      return [ok("default-model", "platform default model: #{settings['default_model']}")] if Harness::Coercion.present?(settings["default_model"])

      seed = seed_model
      fix = seed && -> { @settings_store.update("default_model" => seed) }
      msg = "no platform default_model set (a model-less agent has nothing to resolve; set one in Studio > Settings)"
      msg += " — fixable from #{seed}" if seed
      [Finding.new(check: "default-model", severity: :warn, message: msg, fix: fix)]
    end

    def check_db
      unless @backend.is_a?(Harness::Stores::SQLite)
        return [Finding.new(check: "db", severity: :info,
                            message: "ephemeral backend (HARNESS_DB unset) — config and state do NOT survive a restart", fix: nil)]
      end

      @backend.get("__doctor__", "probe") # a read round-trips the handle; raises if the file is broken
      [ok("db", "durable backend: SQLite (readable)")]
    rescue StandardError => e
      [Finding.new(check: "db", severity: :error, message: "SQLite backend not usable: #{e.class}: #{e.message}", fix: nil)]
    end

    def check_llm_provider
      return [] unless @llm_provider_store

      configured = !Array(@llm_provider_store.apis).empty? || Harness::Coercion.present?(@env["DEEPSEEK_API_KEY"])
      return [ok("llm-provider", "LLM provider configured")] if configured

      [Finding.new(check: "llm-provider", severity: :warn,
                   message: "no LLM provider configured (set DEEPSEEK_API_KEY or add one in Studio > LLM providers) — turns will fail", fix: nil)]
    end

    def check_admin_token
      return [ok("admin-token", "ADMIN_TOKEN set")] if Harness::Coercion.present?(@env["ADMIN_TOKEN"])

      [Finding.new(check: "admin-token", severity: :warn,
                   message: "ADMIN_TOKEN unset — /studio is fail-closed (login denied) and the gateway has no fallback token", fix: nil)]
    end

    # -- helpers -------------------------------------------------------

    def ok(check, message) = Finding.new(check: check, severity: :ok, message: message, fix: nil)

    # A model to seed the platform default from: DEEPSEEK_MODEL env, else the first
    # configured provider's default. nil when nothing to seed from.
    def seed_model
      Harness::Coercion.presence(@env["DEEPSEEK_MODEL"])
    end
  end
end

# frozen_string_literal: true

module Insika
  # `insika doctor` (item 23 / §8.1 — OpenClaw's "strict config + doctor --fix",
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

    def initialize(env: ENV, settings_store: nil, llm_provider_store: nil, tool_store: nil,
                   agent_file_store: nil, backend: nil, extra_env_specs: [])
      @env = env
      @settings_store = settings_store
      @llm_provider_store = llm_provider_store
      @tool_store = tool_store
      @agent_file_store = agent_file_store
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

    def checks = %i[check_env check_settings_schema check_default_model check_db check_llm_provider
                    check_admin_token check_data_tools check_prompt_files check_relay_channel]

    def safe(check)
      Array(send(check))
    rescue StandardError => e
      id = check.to_s.sub(/^check_/, "").tr("_", "-")
      [Finding.new(check: id, severity: :error, message: "check crashed: #{e.class}: #{e.message}", fix: nil)]
    end

    # -- checks --------------------------------------------------------

    def check_env
      findings = Insika::EnvSchema.validate(@env, extra: @extra_env_specs)
      return [ok("env", "environment: no unknown/invalid keys in owned namespaces")] if findings.empty?

      findings.map { |f| Finding.new(check: "env", severity: f.severity, message: f.message, fix: nil) }
    end

    def check_settings_schema
      return [] unless @settings_store

      pending = @settings_store.pending_migrations
      return [ok("settings-schema", "settings schema at v#{Insika::SettingsStore::SCHEMA_VERSION}")] if pending.empty?

      [Finding.new(check: "settings-schema", severity: :warn,
                   message: "settings schema at v#{@settings_store.stored_schema_version}, pending migration(s) #{pending.inspect} to v#{Insika::SettingsStore::SCHEMA_VERSION}",
                   fix: -> { @settings_store.migrate! })]
    end

    def check_default_model
      return [] unless @settings_store

      settings = @settings_store.get
      return [ok("default-model", "platform default model: #{settings['default_model']}")] if Insika::Coercion.present?(settings["default_model"])

      seed = seed_model
      fix = seed && -> { @settings_store.update("default_model" => seed) }
      msg = "no platform default_model set (a model-less agent has nothing to resolve; set one in Studio > Settings)"
      msg += " — fixable from #{seed}" if seed
      [Finding.new(check: "default-model", severity: :warn, message: msg, fix: fix)]
    end

    def check_db
      unless @backend.is_a?(Insika::Stores::SQLite)
        return [Finding.new(check: "db", severity: :info,
                            message: "ephemeral backend (INSIKA_DB unset) — config and state do NOT survive a restart", fix: nil)]
      end

      @backend.get("__doctor__", "probe") # a read round-trips the handle; raises if the file is broken
      [ok("db", "durable backend: SQLite (readable)")]
    rescue StandardError => e
      [Finding.new(check: "db", severity: :error, message: "SQLite backend not usable: #{e.class}: #{e.message}", fix: nil)]
    end

    def check_llm_provider
      return [] unless @llm_provider_store

      configured = !Array(@llm_provider_store.apis).empty? || Insika::Coercion.present?(@env["DEEPSEEK_API_KEY"])
      return [ok("llm-provider", "LLM provider configured")] if configured

      [Finding.new(check: "llm-provider", severity: :warn,
                   message: "no LLM provider configured (set DEEPSEEK_API_KEY or add one in Studio > LLM providers) — turns will fail", fix: nil)]
    end

    def check_admin_token
      return [ok("admin-token", "ADMIN_TOKEN set")] if Insika::Coercion.present?(@env["ADMIN_TOKEN"])

      [Finding.new(check: "admin-token", severity: :warn,
                   message: "ADMIN_TOKEN unset — /studio is fail-closed (login denied) and the gateway has no fallback token", fix: nil)]
    end

    # A half-configured relay is the silent kind of broken (RFC-0011 §6): with only
    # the deliver URL set, nothing is mounted and every inbound POST 404s; with only
    # the token, the engine accepts turns it can never answer and the customer waits
    # forever on a reply that is sitting in the outbox. Both halves or neither.
    def check_relay_channel
      token = Insika::Coercion.present?(@env["INSIKA_RELAY_TOKEN"])
      url   = Insika::Coercion.present?(@env["INSIKA_RELAY_DELIVER_URL"])
      return [] unless token || url

      if token && url
        [ok("relay-channel", "relay channel mounted at /channels/relay/events")]
      elsif token
        [Finding.new(check: "relay-channel", severity: :warn,
                     message: "INSIKA_RELAY_TOKEN set without INSIKA_RELAY_DELIVER_URL — inbound is accepted but no reply can be delivered", fix: nil)]
      else
        [Finding.new(check: "relay-channel", severity: :warn,
                     message: "INSIKA_RELAY_DELIVER_URL set without INSIKA_RELAY_TOKEN — the relay channel is NOT mounted (the token is the switch)", fix: nil)]
      end
    end

    # A stored data-tool whose definition no longer builds is INVISIBLE at runtime: the
    # overlay warns to stderr and drops it, so the agent simply stops seeing the tool.
    # This check is that drop's only report. The one legacy case is auto-fixable: a
    # flat param typed bare `array`, which used to mean "list of strings" — the fix
    # writes that meaning down as `array:string` and changes nothing at runtime.
# A prompt file holding the Ruby #inspect of a Hash instead of markdown. The write
# path refuses this now, but a deployment corrupted BEFORE that guard keeps serving
# the mangled prompt on every turn, and nothing else would ever say so: the file is
# present, non-empty, and the agent answers — worse than a crash. Found on the pilot
# by an `insika refine` report, three weeks after the fact.
def check_prompt_files
  return [] unless @agent_file_store

  agents = @agent_file_store.agents
  wrapped = agents.flat_map do |agent|
    @agent_file_store.list(agent).filter_map do |name|
      next unless wrapped_content?(@agent_file_store.read(agent, name))

      Finding.new(check: "prompt-files", severity: :error, fix: nil,
                  message: "agent '#{agent}' file '#{name}' holds a serialized object, not text — " \
                           "the model receives `{\"content\" => …}` on one line, escapes and all. " \
                           "Recover the markdown from inside the wrapper and write it back.")
    end
  end
  return wrapped if wrapped.any?

  total = agents.sum { |a| @agent_file_store.list(a).length }
  [ok("prompt-files", "#{total} prompt file(s) across #{agents.length} agent(s): all text")]
end

# Cheap and specific: Ruby's inspect of a Hash whose first key is a string. A real
# prompt does not open with `{"…" =>`.
def wrapped_content?(content) = /\A\s*\{\s*"[^"]+"\s*=>/.match?(content.to_s)

    def check_data_tools
      return [] unless @tool_store

      broken = @tool_store.all_raw.filter_map { |raw| broken_tool(raw) }
      total = @tool_store.names.length
      return [ok("data-tools", "#{total} data tool(s): every definition valid")] if broken.empty?

      broken
    end

    def broken_tool(raw)
      Insika::ToolDefinition.from_h(raw)
      nil
    rescue Insika::ValidationError => e
      name = raw.is_a?(Hash) ? raw["name"].to_s : ""
      fix = array_sugar_fix(raw)
      message = "tool '#{name}' is dropped from the catalog: #{e.message}"
      # The autofix preserves the OLD behaviour, which is not always the INTENDED one:
      # a list of objects has been reaching the model declared as a list of strings.
      # Say so, so nobody reads a green doctor as "this tool is right".
      message += " — the fix only writes down what it has been sending (a list of strings); " \
                 "if the API expects objects, paste the real JSON Schema in Studio instead" if fix
      Finding.new(check: "data-tools", severity: :error, fix: fix, message: message)
    end

    # A fix ONLY when spelling the legacy bare `array` explicitly is enough to make the
    # definition build — never a guess at a broken definition we don't understand.
    def array_sugar_fix(raw)
      params = raw.is_a?(Hash) ? raw["parameters"] : nil
      return nil unless params.is_a?(Array) && params.any? { |p| p.is_a?(Hash) && p["type"].to_s == "array" }

      candidate = raw.merge("parameters" => params.map do |p|
        p.is_a?(Hash) && p["type"].to_s == "array" ? p.merge("type" => "array:string") : p
      end)
      Insika::ToolDefinition.from_h(candidate)
      -> { @tool_store.write(candidate) }
    rescue Insika::ValidationError
      nil
    end

    # -- helpers -------------------------------------------------------

    def ok(check, message) = Finding.new(check: check, severity: :ok, message: message, fix: nil)

    # A model to seed the platform default from: DEEPSEEK_MODEL env, else the first
    # configured provider's default. nil when nothing to seed from.
    def seed_model
      Insika::Coercion.presence(@env["DEEPSEEK_MODEL"])
    end
  end
end

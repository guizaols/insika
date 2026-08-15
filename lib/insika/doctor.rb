# frozen_string_literal: true

module Insika
  # `insika doctor` (— OpenClaw's "strict config + doctor --fix",
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
                   agent_file_store: nil, skill_store: nil, skill_catalog: nil,
                   profile_source: nil, backend: nil, extra_env_specs: [],
                   soak_envelope_path: nil)
      @env = env
      @settings_store = settings_store
      @llm_provider_store = llm_provider_store
      @tool_store = tool_store
      @agent_file_store = agent_file_store
      @skill_store = skill_store
      @skill_catalog = skill_catalog
      @profile_source = profile_source
      @backend = backend
      @extra_env_specs = extra_env_specs
      @soak_envelope_path = soak_envelope_path || File.join(Dir.pwd, Insika::Soak::Envelope::DEFAULT_PATH)
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
                    check_admin_token check_data_tools check_prompt_files check_relay_channel
                    check_web_widget check_skill_eager check_skill_drift check_soak_envelope
                    check_turn_timing]

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

    # RFC-0026: the soak envelope (evals/SOAK.md). Absent is :info — not every
    # deployment soaks, and the tooling is optional. Present-and-broken is
    # :error — an envelope that exists but does not parse is a pre-declaration
    # somebody wrote down that the runner will refuse, and only this check says
    # so before the run is attempted.
    def check_soak_envelope
      return [Finding.new(check: "soak-envelope", severity: :info, fix: nil,
                          message: "no soak envelope (#{@soak_envelope_path}) — `insika soak` is available, not required")] unless File.file?(@soak_envelope_path)

      Insika::Soak::Envelope.load(@soak_envelope_path)
      [ok("soak-envelope", "soak envelope parses (#{@soak_envelope_path})")]
    rescue Insika::ConfigError => e
      [Finding.new(check: "soak-envelope", severity: :error, fix: nil,
                   message: "soak envelope present but broken: #{e.message}")]
    end

    # RFC-0026: the soak's prep_p95 gate needs INSIKA_TURN_TIMING on the
    # target. Off is :info normally, and the message names what a soak would
    # refuse — the preflight failure must never be a surprise found 72 hours in.
    def check_turn_timing
      if Insika::EnvSchema.truthy?(Insika::EnvSchema.read("INSIKA_TURN_TIMING", @env))
        [ok("turn-timing", "INSIKA_TURN_TIMING on — the soak's prep_p95 gate is measurable")]
      else
        [Finding.new(check: "turn-timing", severity: :info, fix: nil,
                     message: "INSIKA_TURN_TIMING off — a soak would refuse at preflight (P2: no timing block)")]
      end
    end

    # A half-configured relay is the silent kind of broken: with only
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

    # The widget is the one PUBLIC channel, so its misconfigurations are the ones that
    # cost money rather than just failing. Three of them, in the
    # order they bite: half the switch set (mounted nowhere, or mounted addressing
    # nothing), and a mount with no chat rate limit anywhere — which the channel
    # refuses with a 503 rather than opening, but which reads to an operator as "the
    # widget is broken" unless something says why.
    def check_web_widget
      origins = Insika::Coercion.present?(@env["INSIKA_WIDGET_ORIGINS"])
      agents  = Insika::Coercion.present?(@env["INSIKA_WIDGET_AGENTS"])
      return [] unless origins || agents

      unless origins && agents
        missing = origins ? "INSIKA_WIDGET_AGENTS" : "INSIKA_WIDGET_ORIGINS"
        return [Finding.new(check: "web-widget", severity: :warn,
                            message: "#{missing} unset — the web widget is NOT mounted (both allowlists are the switch)", fix: nil)]
      end

      return [ok("web-widget", "web widget mounted at /channels/web (origins + agents allowlisted, rate limit configured)")] if platform_chat_rate_limit

      # No platform default. A per-agent `limits.chat_rate_limit` still satisfies the
      # gate, and the profiles are not readable from here, so this is a warning and
      # not an error — but it is the likeliest reason a widget answers 503.
      [Finding.new(check: "web-widget", severity: :warn,
                   message: "no platform edge.chat_rate_limit — the widget answers 503 unless EVERY agent in " \
                            "INSIKA_WIDGET_AGENTS sets limits.chat_rate_limit (a public channel with no ceiling is not served)", fix: nil)]
    end

    # Eagerness moved from the SKILL.md frontmatter to `profile.skills_eager`, because
    # skills are SHARED and a flag on the skill forced one decision onto every agent
    # holding it. The parser now ignores `eager:` — which is the quiet kind of upgrade:
    # nothing crashes, the body simply stops being in the prompt. This check is the
    # only thing that says so. Its sibling half is the opposite mistake: a name in
    # `skills_eager` that the agent's `skills` allowlist does not contain is
    # intersected away at runtime, so the operator's intent evaporates in silence.
    def check_skill_eager
      findings = stale_eager_frontmatter + unreachable_eager_names
      return findings if findings.any?
      return [] unless @skill_store || @skill_catalog || @profile_source

      [ok("skill-eager", "skill eagerness: per-agent (profile.skills_eager), no stale frontmatter")]
    end

    def stale_eager_frontmatter
      skill_sources.filter_map do |name, content|
        next unless frontmatter_of(content).key?("eager")

        Finding.new(check: "skill-eager", severity: :warn, fix: nil,
                    message: "skill '#{name}' still declares `eager:` in its frontmatter — the key is IGNORED. " \
                             "Eagerness is per-agent now: put the name in that agent's `skills_eager` " \
                             "(Studio > Skills, or `skills_eager \"#{name}\"` in the DSL).")
      end
    end

    def unreachable_eager_names
      return [] unless @profile_source

      @profile_source.all.flat_map do |profile|
        eager = profile.skills_eager
        next [] unless eager.is_a?(Array)
        next [] if profile.skills.nil? # nil = every skill allowed, so nothing is unreachable

        allowed = Array(profile.skills).map(&:to_s)
        (eager.map(&:to_s) - allowed).map do |name|
          Finding.new(check: "skill-eager", severity: :warn, fix: nil,
                      message: "agent '#{profile.id}' marks skill '#{name}' eager but does not allow it — " \
                               "the name is a no-op. Add it to the agent's skills, or drop it from skills_eager.")
        end
      end
    end

    # { name => raw SKILL.md } across BOTH sources the runtime reads: the disk roots
    # (seed, via the catalog) and the authored store (wins — same precedence as
    # SkillCatalog). The checks parse frontmatter the catalog deliberately drops
    # (`eager:`), so they need the raw text; for a disk skill that is the file itself,
    # and a store-overlaid skill carries a sentinel path that is not a file.
    def skill_sources
      @skill_sources ||= disk_skill_sources.merge(@skill_store ? @skill_store.all : {})
    end

    def disk_skill_sources
      return {} unless @skill_catalog

      @skill_catalog.all.each_with_object({}) do |skill, acc|
        acc[skill.name] = File.read(skill.path, encoding: "UTF-8") if File.file?(skill.path.to_s)
      end
    end

    # The frontmatter block only; a `eager:` line in the BODY is prose, not config.
    def frontmatter_of(content)
      match = content.to_s.match(/\A---\s*\n(.*?)\n---\s*\n/m)
      match ? Insika::Frontmatter.parse(match[1]) : {}
    end

    # Drift between a pack's PROSE and the catalog. Three ways it happened on the
    # pilot, all silent, all found by reading a customer conversation afterwards.
    #
    # Every check here takes MECHANICAL inputs only — skill names, allowlists, agent
    # identities. A check that has to parse prose ("this paragraph declares a count of
    # six") false-positives on the first real pack and takes the doctor's credibility
    # with it, which costs more than the drift it caught.
    def check_skill_drift
      return [] unless (@skill_store || @skill_catalog) && @profile_source

      findings = prompt_files_naming_unallowed_skills + shared_skills_naming_a_holder + broken_companions
      return findings if findings.any?

      [ok("skill-drift", "skill references: prompt files, shared bodies and companions all consistent")]
    end

    # D1 residue. The routing table is GENERATED now (SkillCatalog#format_for_prompt
    # renders each skill with its triggers), so the hand-written companion has no
    # reason to exist — but a pack that still carries one keeps instructing the model
    # about skills the agent cannot load. Skill names are known ids, so this is a grep.
    def prompt_files_naming_unallowed_skills
      return [] unless @agent_file_store

      catalog = skill_sources.keys
      @profile_source.all.flat_map do |profile|
        next [] if profile.skills.nil? # nil = everything allowed, nothing to be outside of

        allowed = Array(profile.skills).map(&:to_s)
        orphans = catalog - allowed
        next [] if orphans.empty?

        @agent_file_store.list(profile.id).flat_map do |file|
          body = @agent_file_store.read(profile.id, file).to_s
          orphans.select { |name| mentions?(body, name) }.map do |name|
            Finding.new(check: "skill-drift", severity: :warn, fix: nil,
                        message: "agent '#{profile.id}' file '#{file}' names skill '#{name}', which is NOT in its " \
                                 "skills allowlist — the model is being told to use something it cannot load. " \
                                 "Allow the skill, or drop the reference (the skill table is generated).")
          end
        end
      end
    end

    # D2. A skill in more than one allowlist that names one of its OWN holders in its
    # text is specialized text in shared clothing — the pilot served the Cacau Show
    # agent three shared skills that each said "na Natura". Specialize it per agent
    # (write_skill with `agent:`) instead of leaving one store's policy in a shared body.
    #
    # Merchant vocabulary beyond the holders' identities is deliberately out of scope:
    # there is no mechanical source for it.
    def shared_skills_naming_a_holder
      holders = skill_holders
      specialized = specialized_by
      skill_sources.flat_map do |name, content|
        owners = holders[name].to_a
        next [] if owners.length < 2

        # Who still READS this shared body: a holder with its own version reads that
        # instead, so it stops being a victim — but its identity in the shared text
        # keeps poisoning whoever is left. Identity comes from ALL holders; only the
        # readers shrink as specializations land, so the finding clears when the last
        # victim stops reading, never merely because the named holder moved out.
        readers = owners - specialized[name].to_a
        owners.flat_map do |owner|
          victims = (readers - [owner]).sort
          next [] if victims.empty?

          identity_terms(owner).select { |term| mentions?(content, term) }.map do |term|
            Finding.new(check: "skill-drift", severity: :warn, fix: nil,
                        message: "shared skill '#{name}' names '#{term}', the identity of '#{owner}' — " \
                                 "#{victims.join(', ')} read(s) #{owner}'s text as their own. Specialize " \
                                 "'#{owner}' if it needs that text, and remove it from the shared body.")
          end
        end
      end
    end

    # D3 residue, the half `companions:` cannot prevent: a body that points at another
    # catalog skill without declaring it (so the pair can still break apart), and a
    # declared companion an agent is not allowed to load (so the pair breaks for THAT
    # agent, silently, since the engine will not widen an allowlist on its own).
    def broken_companions
      names = skill_sources.keys
      undeclared = skill_sources.flat_map do |name, content|
        declared = declared_companions(content)
        (names - [name] - declared).select { |other| mentions?(body_of(content), other) }.map do |other|
          Finding.new(check: "skill-drift", severity: :warn, fix: nil,
                      message: "skill '#{name}' references skill '#{other}' in its body without declaring it a " \
                               "companion — the two can arrive apart, and half a recipe is worse than none. " \
                               "Add `companions: [#{other}]` to '#{name}'.")
        end
      end
      undeclared + companions_outside_allowlists
    end

    # Same lenient reading as SkillCatalog#parse_list: a YAML list, or the whole value
    # as one comma-separated String when the tolerant parser had to fall back.
    def declared_companions(content)
      raw = frontmatter_of(content)["companions"]
      Array(raw).flat_map { |c| c.to_s.split(",") }.map(&:strip).reject(&:empty?)
    end

    def companions_outside_allowlists
      declared = skill_sources.each_with_object({}) do |(name, content), acc|
        list = declared_companions(content)
        acc[name] = list unless list.empty?
      end
      return [] if declared.empty?

      @profile_source.all.flat_map do |profile|
        next [] if profile.skills.nil?

        allowed = Array(profile.skills).map(&:to_s)
        declared.flat_map do |name, companions|
          next [] unless allowed.include?(name)

          (companions - allowed).map do |missing|
            Finding.new(check: "skill-drift", severity: :warn, fix: nil,
                        message: "agent '#{profile.id}' allows skill '#{name}' but not its companion '#{missing}' — " \
                                 "the pair cannot travel together for this agent. Allow '#{missing}' too.")
          end
        end
      end
    end

    # { skill name => [agent ids that have their OWN version] }.
    def specialized_by
      return {} unless @skill_store.respond_to?(:agents)

      @skill_store.agents.each_with_object({}) do |agent, acc|
        @skill_store.names(agent: agent).each { |name| (acc[name] ||= []) << agent }
      end
    end

    # { skill name => Set(agent ids that allow it explicitly) }. An agent with
    # skills=nil allows everything and is not a "holder": it says nothing about which
    # skills were meant to be shared.
    def skill_holders
      @profile_source.all.each_with_object({}) do |profile, acc|
        next if profile.skills.nil?

        Array(profile.skills).each { |name| (acc[name.to_s] ||= []) << profile.id }
      end
    end

    # An agent's identity as WORDS: the distinctive tokens of its id plus whatever it
    # calls itself in metadata. Structural tokens (agent/store/bot/…) are dropped and
    # short ones ignored — "store" appears in every retail skill ever written, and one
    # false positive is enough for an operator to stop reading the doctor.
    IDENTITY_STOPWORDS = %w[agent agente store shop loja bot assistant assistente atendimento
                            prod staging demo test main default].freeze

    def identity_terms(agent_id)
      profile = @profile_source.fetch(agent_id)
      meta = profile ? (profile.metadata || {}) : {}
      raw = [agent_id.to_s.split(/[-_.\s]+/), meta["name"], meta["display_name"], meta["store_name"]]
      raw.flatten.compact.map { |t| t.to_s.strip }
         .reject { |t| t.length < 4 || IDENTITY_STOPWORDS.include?(t.downcase) }
         .uniq
    end

    # Whole-word, case- and accent-insensitive — the same reading the trigger matcher
    # uses, for the same reason: a substring hit inside a longer word is a false
    # positive, and one of those is enough to lose the operator.
    def mentions?(text, term)
      needle = fold(term)
      return false if needle.empty?

      /(?<![[:alnum:]])#{Regexp.escape(needle)}(?![[:alnum:]])/.match?(fold(text))
    end

    def fold(text) = text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase

    def body_of(content) = content.to_s.sub(/\A---\s*\n.*?\n---\s*\n/m, "")

    def platform_chat_rate_limit
      value = ((@settings_store&.get || {})["edge"] || {})["chat_rate_limit"]
      value.to_i.positive?
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

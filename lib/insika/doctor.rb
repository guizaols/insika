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

    # RFC-0036 C3: one entry of the domain inventory. The engine never GUESSES
    # a store (D3) — every entry is something a deployment explicitly declared,
    # or the built-in corpus still in effect (source "gem-default"). A broken
    # enumerator degrades to one error-marked entry, never raises.
    DomainEntry = Data.define(:kind, :agent, :detail, :source, :how_to_clear) do
      def to_h
        { "kind" => kind, "agent" => agent, "detail" => detail,
          "source" => source, "how_to_clear" => how_to_clear }.compact
      end
    end

    # The domain section of the doctor: the RFC's E2 proof surface. Read-only
    # and informational — it never fails the exit code (a pilot reporting its
    # own artifacts exits 0).
    DomainReport = Data.define(:generated_at, :gem_version, :entries) do
      def empty? = entries.empty?
      def count  = entries.length

      def to_h
        { "generated_at" => generated_at, "gem_version" => gem_version,
          "count" => count, "entries" => entries.map(&:to_h) }
      end

      # The human section (prints AFTER the findings — a section, not a finding).
      def to_s
        header =
          if count.zero?
            "domain: 0 artifacts — a bare install declares no store and ships no corpus in use"
          else
            "domain: #{count} artifact(s) — declared by the deployment or inherited from the gem default"
          end
        lines = entries.map do |e|
          agent = e.agent ? "#{e.agent}: " : ""
          source = e.source ? " (#{e.source})" : ""
          clear = e.how_to_clear ? " — clear: #{e.how_to_clear}" : ""
          "  [#{e.kind}] #{agent}#{e.detail}#{source}#{clear}"
        end
        ([header] + lines).join("\n")
      end
    end

    def initialize(env: ENV, settings_store: nil, llm_provider_store: nil, tool_store: nil,
                   agent_file_store: nil, skill_store: nil, skill_catalog: nil,
                   profile_source: nil, backend: nil, extra_env_specs: [],
                   shadow_pair_store: nil, soak_envelope_path: nil, context_providers: nil,
                   memory_store: nil, agent_ids: nil, funnel_store: nil, outcome_store: nil,
                   followup_store: nil, contact_store: nil, proposal_store: nil,
                   harvest_store: nil, harvest_criterion: nil)
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
      @shadow_pair_store = shadow_pair_store
      @soak_envelope_path = soak_envelope_path || File.join(Dir.pwd, Insika::Soak::Envelope::DEFAULT_PATH)
      # RFC-0030 C7: [ContextProvider | Class] — classes accepted so the CLI
      # can pass the builtin set without deps; the check only reads .layer /
      # .name. nil = skip.
      @context_providers = context_providers
      # RFC-0031 C6: the memory-scopes check — Insika::MemoryStore | nil = skip;
      # agent_ids excuse bare cells named like an agent (the agent-memory tab's).
      @memory_store = memory_store
      @agent_ids = Array(agent_ids).map(&:to_s)
      # RFC-0032 C7: the outcome-funnel check — nil collaborators = the check
      # reports declarations only (env-only callers stay cheap).
      @funnel_store = funnel_store
      @outcome_store = outcome_store
      # RFC-0033 C12: the follow-up check — nil collaborators = the check
      # reports declarations only.
      @followup_store = followup_store
      @contact_store = contact_store
      # RFC-0034 C10: the distillation check — nil collaborator = the check
      # reports declarations only (counts skipped).
      @proposal_store = proposal_store
      # RFC-0035 C15: the harvest check — nil collaborators = the check
      # reports declarations only (counts skipped).
      @harvest_store = harvest_store
      @harvest_criterion = harvest_criterion
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

    # RFC-0036 C3 — the domain inventory: what a deployment declares (personas
    # with a metadata.domain tag, outcome funnels, tool evidence) plus the
    # built-in pt-BR corpora still in effect. Read-only: informational, never
    # a gate — a pilot reporting its own artifacts must exit 0.
    def domain
      entries = %i[personas corpora funnels evidence].flat_map { |section| safe_domain(section) }.compact
      DomainReport.new(generated_at: Time.now.utc.iso8601,
                       gem_version: Insika::VERSION,
                       entries: entries.freeze)
    end

    private

    def checks = %i[check_env check_settings_schema check_default_model check_db check_llm_provider
                    check_admin_token check_data_tools check_prompt_files check_relay_channel
                    check_web_widget check_skill_eager check_skill_drift check_shadow_parity
                    check_soak_envelope check_turn_timing check_grounding check_cache_layers
                    check_memory_scopes check_funnel_declarations check_followup check_distill
                    check_harvest check_guardrail_corpora]

    def safe(check)
      Array(send(check))
    rescue StandardError => e
      id = check.to_s.sub(/^check_/, "").tr("_", "-")
      [Finding.new(check: id, severity: :error, message: "check crashed: #{e.class}: #{e.message}", fix: nil)]
    end

    # RFC-0036 C3: one domain section, wrapped — a broken read degrades to one
    # error-marked entry, never raises (the same discipline as `safe`).
    def safe_domain(section)
      send(:"domain_#{section}")
    rescue StandardError => e
      [DomainEntry.new(kind: "error", agent: nil,
                       detail: "#{section}: read failed — #{e.class}: #{e.message}",
                       source: nil, how_to_clear: nil)]
    end

    # 1/4 personas/packs — `profile.metadata["domain"]` (pack `agent.config.json`
    # passes it through; the DSL sets it via `metadata domain: "…"`).
    def domain_personas
      return [] unless @profile_source

      @profile_source.all.filter_map do |p|
        m = p.metadata
        tag = m && m["domain"]
        next if !Coercion.present?(tag)

        DomainEntry.new(kind: "persona", agent: p.id, detail: "domain=#{tag}",
                        source: "deployment", how_to_clear: nil)
      end
    end

    # 2/4 corpora — the built-in pt-BR corpus still in effect (gem default) and
    # the built-in pt-BR safe replies that are not fully overridden.
    def domain_corpora
      return [] unless @profile_source

      @profile_source.all.each_with_object([]) do |p, acc|
        config = Insika::Safety::Config.from_profile(p)
        next unless config.enabled?

        if config.corpus_languages.include?("pt-BR")
          acc << DomainEntry.new(kind: "guardrail-corpus", agent: p.id,
                                 detail: "languages=#{config.corpus_languages.join(',')}",
                                 source: "gem-default",
                                 how_to_clear: "docs/domain.md#guardrails")
        end
        fallback = builtin_response_categories(config)
        next if fallback.empty?

        acc << DomainEntry.new(kind: "safe-responses", agent: p.id,
                               detail: "categories=#{fallback.join(',')}",
                               source: "gem-default",
                               how_to_clear: "docs/domain.md#guardrails")
      end
    end

    # The safe-reply categories that still resolve to the built-in pt-BR
    # DEFAULTS (a category the agent overrode — or a catch-all `default` that
    # replaces every category — contributes none).
    def builtin_response_categories(config)
      Insika::Safety::SafeResponses::DEFAULTS.keys.select do |cat|
        Insika::Safety::SafeResponses.for(cat, overrides: config.responses) == Insika::Safety::SafeResponses::DEFAULTS[cat]
      end
    end

    # 3/4 funnels — the RFC-0032 declaration shape. Absent in the tree (or on a
    # profile) -> absent in the report: a bare install shows no funnel and no
    # stage names at all (the vocabulary note).
    def domain_funnels
      return [] unless @profile_source

      @profile_source.all.filter_map do |p|
        next unless p.respond_to?(:funnel) && p.funnel.is_a?(Hash) && !p.funnel.empty?

        stages = Array(p.funnel["stages"]).join(",")
        primary = p.funnel["primary"]
        detail = +"stages=#{stages}"
        detail << ", primary=#{primary}" if Coercion.present?(primary)
        DomainEntry.new(kind: "funnel", agent: p.id, detail: detail,
                        source: "deployment", how_to_clear: nil)
      end
    end

    # 4/4 evidence — tool manifests carrying the RFC-0029 `evidence: <kind>`
    # vocabulary. Kinds are pack vocabulary, never gem constants.
    def domain_evidence
      return [] unless @tool_store

      @tool_store.all_raw.filter_map do |raw|
        ev = raw["evidence"]
        kind = ev.is_a?(Hash) ? ev["kind"] : ev
        next if !Coercion.present?(kind)

        DomainEntry.new(kind: "evidence", agent: nil,
                        detail: "#{raw["name"]}: #{kind}",
                        source: "deployment", how_to_clear: nil)
      end
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

    # RFC-0030 D8: the doctor cannot run a turn, so it cannot prove purity — it
    # CAN verify the declaration. An identity-layer provider that is not one of
    # the engine's three known-safe classes is :warn; one of the engine's
    # known-volatile classes overriding to :identity is :error (a volatile
    # identity block bills a cache write every turn).
    IDENTITY_BUILTINS = %w[
      Insika::Context::Providers::Prompt
      Insika::Context::Providers::Skill
      Insika::Context::Providers::ToolSearch
    ].freeze
    VOLATILE_BUILTINS = %w[
      Insika::Context::Providers::Request
      Insika::Context::Providers::Session
      Insika::Context::Providers::Memory
      Insika::Context::Providers::SkillTrigger
    ].freeze

    def check_cache_layers
      return [] unless @context_providers

      findings = @context_providers.flat_map do |p|
        name = p.is_a?(Class) ? p.name : p.class.name
        layer = declared_layer(p)
        next [] unless layer == :identity
        next [] if builtin_of?(p, IDENTITY_BUILTINS)

        known_volatile = builtin_of?(p, VOLATILE_BUILTINS)
        [Finding.new(check: "cache-layers", severity: known_volatile ? :error : :warn, fix: nil,
                     message: "context provider '#{name}' declares layer :identity but is " \
                              "#{known_volatile ? 'engine-known turn-dependent' : 'not engine-verified'} — " \
                              "a volatile block above the cache boundary bills a cache WRITE every turn. " \
                              "Verify the output is byte-stable across turns (no timestamps, no per-turn data).")]
      end
      return findings if findings.any?

      [ok("cache-layers", "context layers: #{@context_providers.size} provider(s), identity partition verified")]
    end

    # The declaration is an INSTANCE method, so a class passed as-is does not
    # respond to .layer. Evaluate it on a bare instance (allocate skips
    # initialize — the declaration must not depend on constructor state; a
    # method that does degrades to :volatile, the conservative side). This is
    # what makes an explicit `def layer = :volatile` read as volatile instead of
    # a warning.
    def declared_layer(provider)
      return provider.layer unless provider.is_a?(Class)
      return :volatile unless provider.instance_methods.include?(:layer)

      provider.instance_method(:layer).bind_call(provider.allocate)
    rescue StandardError
      :volatile
    end

    # The declaration check is by CLASS: a subclass of an engine-known provider
    # inherits its data source (a Memory subclass is still turn-dependent no
    # matter what it overrides). Accepts instances OR classes; anonymous
    # classes (Class.new(...)) have no .name, so the ancestor walk is what
    # catches them.
    def builtin_of?(provider, consts)
      klass_of = provider.is_a?(Class) ? provider : provider.class

      consts.any? do |c|
        klass = Object.const_get(c)
        klass_of == klass || klass_of < klass
      rescue NameError
        false
      end
    end

    # RFC-0029 D7: grounding with a matcher that matches NOTHING (no sku) is
    # harmless but useless — every claim passes and the audit reads zero. A
    # warning, never an error: the pack owns matcher quality; the engine refuses
    # only uncompileable data.
    def check_grounding
      return [] unless @profile_source

      findings = @profile_source.all.flat_map do |profile|
        grounding = profile.respond_to?(:grounding) ? profile.grounding : nil
        next [] if grounding.nil? || grounding == false
        next [] if Coercion.present?(grounding["matcher"].is_a?(Hash) ? grounding["matcher"]["sku"] : nil)

        [Finding.new(check: "grounding", severity: :warn, fix: nil,
                     message: "agent '#{profile.id}' has grounding enabled but no matcher.sku — " \
                              "it matches nothing, so no claim is ever flagged or cut. " \
                              "Add the store's SKU regex to grounding.matcher.sku.")]
      end
      findings.empty? ? [ok("grounding", "grounding: no agent with an empty matcher")] : findings
    end

    # RFC-0031 C6: the memory-scopes check. Reads the cells via C1's enumeration.
    # Warn-only: the doctor never moves data across cells (D2).
    #
    # What it flags, and what it deliberately does NOT:
    # - "memory:chat:<session id>" cells are the engine's OWN per-session shape
    #   (RFC-0031) — never flagged.
    # - a BARE cell is the DESIGNED single-tenant customer shape ("nil tenant +
    #   customer -> memory:<customer>, NEVER _default") — with no tenant to
    #   migrate to, warning is a false positive, so the check only fires in a
    #   multi_tenant deployment (INSIKA_TENANCY), where every customer must
    #   live in a [tenant:]customer cell.
    # - `agent_ids:` excuses the agent-memory tab's cells (a bare cell named
    #   like an agent is a profile, not a customer).
    def check_memory_scopes
      return [] unless @memory_store

      findings = []
      @memory_store.cells.each do |cell|
        next if Insika::MemoryStore.session_cell?(cell) # the engine's per-session cell
        next if cell[:customer].nil? # _default — the shared cell
        next if cell[:tenant] # [tenant:]customer — scoped
        next if single_tenant? # bare = the designed single-tenant customer shape
        next if @agent_ids.include?(cell[:customer].to_s)

        findings << Finding.new(check: "memory-scopes", severity: :warn, fix: nil,
                                message: "memory cell '#{cell[:scope]}' is unscoped — in a multi-tenant " \
                                         "deployment customer memory must live in a [tenant:]customer cell. " \
                                         "Migrate it, or confirm it is an agent-memory cell " \
                                         "(a bare cell named like an agent is excused).")
      end
      return findings if findings.any?

      [ok("memory-scopes", "memory cells: #{@memory_store.cells.size}, all scoped")]
    end

    def single_tenant?
      Insika::EnvSchema.read("INSIKA_TENANCY", @env) != "multi_tenant"
    end

    # RFC-0032 C7: the outcome-funnel check — declarations on every pilot store,
    # the plan's "no 1.0 target without a remeasure" backstop. Warn/error only:
    # the doctor never rewrites a declaration (the pack is authoritative;
    # `--fix` has nothing to fix here).
    def check_funnel_declarations
      return [] unless @profile_source

      findings = @profile_source.all.flat_map do |profile|
        next [] if profile.funnel.nil?

        decl = Insika::FunnelDeclaration.parse(profile.funnel)
        if decl.nil?
          # D8: the fold skips this agent until it is fixed — the doctor is the
          # only report of why.
          [Finding.new(check: "outcome-funnel", severity: :error, fix: nil,
                       message: "agent '#{profile.id}': malformed funnel declaration — " \
                                "#{funnel_defect(profile.funnel)}. The fold skips it " \
                                "until this is fixed.")]
        else
          [ok("outcome-funnel",
              "agent '#{profile.id}': outcome funnel declared — #{decl.stages.length} " \
              "stages, primary '#{decl.primary}', window #{decl.attribution_window}")] +
            funnel_data_findings(profile, decl)
        end
      end

      # RFC §2: visibility is the feature — a profile with outcomes but no
      # funnel shows the hole. Warn only; the pack owns the vocabulary.
      without = outcomes_without_funnel
      without.each do |agent, count|
        findings << Finding.new(check: "outcome-funnel", severity: :warn, fix: nil,
                                message: "agent '#{agent}' records #{count} outcomes and " \
                                         "declares no funnel: nothing folds — the funnel " \
                                         "shows the hole. Add a `funnel:` block to the pack.")
      end

      return findings unless findings.empty?

      [ok("outcome-funnel", "outcome funnels: every declared funnel valid")]
    end

    # -> { agent_id => outcome count } — profiles with records but no funnel.
    # ONE scan of the outcome store, grouped by agent (a per-profile `all`
    # would scan it once PER profile — the store is not that big, but the
    # key shape exists precisely so this stays a single pass).
    def outcomes_without_funnel
      return {} unless @outcome_store && @profile_source

      counts = @outcome_store.all.group_by(&:agent).transform_values(&:size)
      @profile_source.all.each_with_object({}) do |p, acc|
        next unless p.funnel.nil?

        n = counts[p.id.to_s].to_i
        acc[p.id.to_s] = n if n.positive?
      end
    end

    # The named defect, for the error message. `parse!` gives the exact field.
    def funnel_defect(hash)
      Insika::FunnelDeclaration.parse!(hash).to_s
    rescue Insika::ValidationError => e
      e.message
    end

    # Data-age findings, gated on the optional collaborators (nil = skip, env-only
    # callers stay cheap). Tenant-agnostic: folds are per (tenant, agent), so the
    # check reads the store's `pairs` and aggregates over every tenant of the agent
    # (a single-tenant deployment reads the "platform" pair).
    def funnel_data_findings(profile, decl)
      return [] unless @funnel_store

      pairs = @funnel_store.pairs.select { |p| p[:agent] == profile.id.to_s }
      return [] if pairs.empty?

      findings = []
      folded_days = 0
      primary_count = 0
      baseline = false
      pairs.each do |pair|
        days = @funnel_store.days(tenant: pair[:tenant], agent: pair[:agent])
        folded_days += days.size
        primary_count += days.values.sum { |c| c[decl.primary].to_i }
        baseline ||= !@funnel_store.baseline(tenant: pair[:tenant], agent: pair[:agent]).nil?
      end

      if primary_count.zero?
        findings << Finding.new(check: "outcome-funnel", severity: :info, fix: nil,
                                message: "agent '#{profile.id}': the primary event " \
                                         "'#{decl.primary}' was never observed over the " \
                                         "folded days — check the integration.")
      end
      if folded_days >= 28 && !baseline
        findings << Finding.new(check: "outcome-funnel", severity: :info, fix: nil,
                                message: "agent '#{profile.id}': #{folded_days} folded " \
                                         "days and no baseline frozen — RFC-0033/0035 " \
                                         "read the baseline. Freeze it in the Studio.")
      end
      findings
    end

    # RFC-0033 C12: the follow-up check — declarations validated where they are
    # declared (D9), plus the two data-age reads that answer "whose follow-ups
    # will fire" and "what is blocked right now" without reading the store:
    #   · a pending record whose `at` is more than one claim window in the past
    #     will NEVER fire — a blocked rule or a broken policy is holding it
    #     (warn; the Follow-ups page is the drill);
    #   · revoked contact cells per tenant (info — the human opt-out bar).
    def check_followup
      return [] unless @profile_source

      declared = @profile_source.all.select do |profile|
        profile.respond_to?(:followup) && !profile.followup.nil?
      end
      # a bare install (no follow-up on any profile) reports NOTHING — no
      # follow-up vocabulary leaks into the doctor of a store that never
      # scheduled one.
      return [] if declared.empty?

      findings = declared.flat_map do |profile|
        followup = profile.followup
        decl = Insika::FollowupPolicy.parse(followup)
        if decl.nil?
          [Finding.new(check: "follow-up", severity: :error, fix: nil,
                       message: "agent '#{profile.id}': malformed follow-up declaration — " \
                                "#{followup_defect(followup)}. The engine will never fire its " \
                                "follow-ups until this is fixed.")]
        else
          [ok("follow-up",
              "agent '#{profile.id}': follow-up declared — arm #{decl.arm}, " \
              "#{decl.quiet_hours ? "quiet hours #{decl.quiet_hours.start}-#{decl.quiet_hours.end} " \
              "<#{decl.quiet_hours.timezone}>" : 'no quiet hours'}, " \
              "#{decl.cancel_keywords.size} keyword(s), " \
              "silence after #{decl.silence_after_sends} send(s)")] +
            followup_data_findings(profile, decl)
        end
      end

      findings
    end

    # The named defect, for the error message — `parse!` gives the exact field.
    def followup_defect(hash)
      Insika::FollowupPolicy.parse!(hash).to_s
    rescue Insika::ValidationError => e
      e.message
    end

    # Data-age findings, gated on the optional collaborators (nil = skip,
    # env-only callers stay cheap).
    def followup_data_findings(profile, decl)
      return [] unless @followup_store && @contact_store

      findings = []
      # a pending record more than one claim window PAST its `at` (the sign:
      # due(now - window)) is a promise the tick will never honor. A
      # quiet-hours deferral is EXCLUDED — that record still fires next pass;
      # only a record the tick could fire RIGHT NOW and doesn't is stuck.
      now = Time.now.utc
      window = Insika::FollowupEngine::DEFAULT_WINDOW
      deferred_now = decl.quiet?(now)
      stale = @followup_store.due(now: now - window)
                 .reject { |r| r.agent != profile.id.to_s }
                 .reject { deferred_now }
      unless stale.empty?
        findings << Finding.new(check: "follow-up", severity: :warn, fix: nil,
                                message: "agent '#{profile.id}': #{stale.size} pending " \
                                         "follow-up(s) past their scheduled time by more than " \
                                         "one claim window — the tick will never fire them. A " \
                                         "blocked rule or a broken policy is pending; see the " \
                                         "Follow-ups page.")
      end
      revoked_for(profile).each do |tenant, count|
        findings << Finding.new(check: "follow-up", severity: :info, fix: nil,
                                message: "agent '#{profile.id}': #{count} revoked contact cell(s) " \
                                         "in tenant #{tenant.inspect} — the human opt-out bar " \
                                         "(opt-outs are per tenant/customer, shared across agents).")
      end
      findings
    end

    # { tenant => revoked-cell count } among the cells this agent may message.
    # The contact cell is per (tenant, customer) — shared across agents (D2's
    # multi-agent note), so the count is a per-tenant tally of revoked cells.
    def revoked_for(_profile)
      return {} unless @contact_store

      @contact_store.cells.each_with_object(Hash.new(0)) do |(key, cell), tally|
        next unless cell["state"] == "revoked"

        tally[key.split(":", 2).first] += 1
      end
    end

    # RFC-0034 C10: the distillation check — per profile WITH a `distill`
    # hash: a declared-and-enabled distiller with NO resolvable model (no
    # distill.model, no platform utility_model) can never run — the warn is
    # the "declared but dead" signal (D4 — the engine never guesses a model).
    # A bare install reports one ok ("off"), unlike follow-up's silence: the
    # Facts page exists with or without declarations and the doctor names why
    # it stays empty. nil proposal_store = declarations only (counts skipped).
    def check_distill
      return [] unless @profile_source

      declared = @profile_source.all.select do |profile|
        profile.respond_to?(:distill) && !profile.distill.nil?
      end
      return [ok("distill", "distillation off — no agent declares it")] if declared.empty?

      settings = @settings_store ? @settings_store.get : {}
      # one scan pair per run, not per declared profile (the counts are the
      # store's, printed identically on each line).
      counts = @proposal_store ? distill_counts : nil
      declared.flat_map do |profile|
        config = profile.distill
        if Coercion.truthy?(config["enabled"]) &&
           Coercion.presence(config["model"]).nil? &&
           Coercion.presence(settings["utility_model"]).nil?
          [Finding.new(check: "distill", severity: :warn, fix: nil,
                       message: "agent '#{profile.id}': the distiller is declared but has " \
                                "no model slot — distillation will never run (set " \
                                "distill.model or the platform utility_model).")]
        else
          suffix = counts ? " — #{counts[:pending]} proposal(s) pending, #{counts[:stale]} stale" : ""
          [ok("distill", "agent '#{profile.id}': distillation declared#{suffix}")]
        end
      end
    end

    def distill_counts
      { pending: @proposal_store.pending(limit: 10_000).size,
        stale: @proposal_store.stale(limit: 10_000).size }
    end

    # RFC-0035 C15: the harvest check — per profile WITH a harvest hash:
    #   declared-without-model warn (D12), no grounding matcher warn (D3),
    #   malformed negative list error (D4), else ok with the pending counts.
    # With @harvest_criterion: the loaded criterion line + a warn when the
    # file at its path no longer loads (the frozen rule moved).
    def check_harvest
      return [] unless @profile_source

      declared = @profile_source.all.select do |profile|
        profile.respond_to?(:harvest) && !profile.harvest.nil?
      end
      findings = []
      if declared.empty?
        findings << ok("harvest", "harvest off — no agent declares it")
      else
        settings = @settings_store ? @settings_store.get : {}
        declared.each do |profile|
          config = profile.harvest
          id = profile.id
          if Coercion.truthy?(config["enabled"]) &&
             Coercion.presence(config.dig("miner", "model")).nil? &&
             Coercion.presence(settings["utility_model"]).nil?
            findings << Finding.new(check: "harvest", severity: :warn, fix: nil,
                                    message: "agent '#{id}': the harvester is declared but has no " \
                                             "model slot — mining will never run (set " \
                                             "harvest.miner.model or the platform utility_model).")
          end
          grounding = begin
            Insika::Grounding.parse(profile.grounding)
          rescue Insika::ValidationError
            nil
          end
          if Coercion.truthy?(config["enabled"]) && (grounding.nil? || !grounding.matcher.sku?)
            findings << Finding.new(check: "harvest", severity: :warn, fix: nil,
                                    message: "agent '#{id}': product claims cannot be verified — " \
                                             "mining is skipped (set grounding.matcher.sku).")
          end
          if config["negative_list"].is_a?(Array) &&
             Insika::Harvest::NegativeList.parse(config["negative_list"]).nil?
            findings << Finding.new(check: "harvest", severity: :error, fix: nil,
                                    message: "agent '#{id}': the harvest.negative_list is malformed " \
                                             "— the whole list is refused (half a list silently " \
                                             "admits what the store banned).")
          end
          suffix = harvest_counts(id) if @harvest_store
          findings << ok("harvest", "agent '#{id}': harvest declared#{suffix}")
        end
      end
      if @harvest_criterion
        findings << ok("harvest-criterion",
                       "criterion #{@harvest_criterion.rule.metric} / #{@harvest_criterion.rule.window} " \
                       "threshold #{@harvest_criterion.rule.threshold} (#{@harvest_criterion.sha})")
        begin
          Insika::Harvest::Criterion.load(@harvest_criterion.path)
        rescue Insika::ConfigError, Insika::ValidationError
          findings << Finding.new(check: "harvest-criterion", severity: :warn, fix: nil,
                                  message: "the criterion file at #{@harvest_criterion.path} no longer " \
                                           "loads — the frozen rule moved since boot.")
        end
      end
      findings
    end

    def harvest_counts(agent_id)
      awaiting = @harvest_store.candidates(agent_id: agent_id, status: "awaiting_approval").size
      pending = @harvest_store.candidates(agent_id: agent_id, status: "pending").size
      " — #{awaiting} awaiting, #{pending} pending"
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

    # RFC-0025 shadow parity (C9). Shadow holds raw customer conversations, so
    # every dangerous configuration says so BEFORE the experiment starts — and
    # the one automated reminder to turn it off. The pairs themselves are only
    # loaded when shadow is ON (a full scan pays for customer text); the off
    # path needs just a count, which the store answers from its keys.
    def check_shadow_parity
      shadow_on = Insika::EnvSchema.truthy?(@env["INSIKA_RELAY_SHADOW"])
      path = Insika::EnvSchema.read("INSIKA_PARITY_CRITERION", @env) || "evals/PARITY.md"

      unless shadow_on
        stored = @shadow_pair_store ? @shadow_pair_store.size : 0
        return [] if stored.zero?

        return [ok("shadow-parity",
                   "shadow off — #{stored} pair(s) still stored, evidence is not forgotten")]
      end

      pairs = @shadow_pair_store ? @shadow_pair_store.each.to_a : []

      criterion = begin
        Insika::Parity::Criterion.load(path)
      rescue Insika::Error => e
        return [Finding.new(check: "shadow-parity", severity: :error, fix: nil,
                            message: "shadow on but the criterion did not load from #{path}: #{e.message}")]
      end

      findings = [ok("shadow-parity", "shadow on — criterion frozen (#{criterion.sha}) at #{path}")]
      if Insika::EnvSchema.present?(@env["INSIKA_RELAY_DELIVER_URL"])
        findings << Finding.new(check: "shadow-parity", severity: :warn, fix: nil,
                                message: "INSIKA_RELAY_DELIVER_URL is set — the URL is INERT: a shadow relay never delivers")
      end
      judges = ((@settings_store&.get || {})["evals"] || {})
      if Array(judges["judges"]).reject { |j| j["model"].to_s.strip.empty? }.empty?
        findings << Finding.new(check: "shadow-parity", severity: :warn, fix: nil,
                                message: "no judges in settings['evals'] — pairs will accumulate and nothing can judge them")
      end
      window = criterion.rule.window_days
      oldest = pairs.filter_map { |p| parse_pair_time(p) }.min
      if oldest && oldest < Time.now.utc - (2 * window * 86_400)
        findings << Finding.new(check: "shadow-parity", severity: :warn, fix: nil,
                                message: "the oldest pair is older than 2 × window_days — shadow is not a permanent mode; judge and turn it off")
      end
      findings
    end

    def parse_pair_time(pair)
      Time.iso8601(pair.created_at.to_s)
    rescue ArgumentError
      nil
    end

    # RFC-0036 C2/C3: the BOOT gate for a malformed guardrail corpus. A typo'd
    # language/family or a broken pattern source raises ValidationError inside
    # Safety::Config on the FIRST TURN — mid-conversation, unrecoverable. This
    # check makes `insika doctor` the place it surfaces instead: an :error
    # finding (non-zero exit), so a deployment learns at boot, never mid-turn.
    def check_guardrail_corpora
      return [] unless @profile_source

      findings = @profile_source.all.each_with_object([]) do |p, acc|
        Insika::Safety::Config.from_profile(p) # compiles the corpus — raises on a bad declaration
      rescue Insika::ValidationError => e
        acc << Finding.new(check: "guardrail-corpora", severity: :error, fix: nil,
                           message: "agent '#{p.id}': malformed guardrails.corpora — #{e.message}. " \
                                    "Every message would fail the guardrail; fix the declaration " \
                                    "(docs/domain.md#guardrails).")
      end
      return findings unless findings.empty?

      [ok("guardrail-corpora", "guardrail corpora: every declaration compiles")]
    end

    def ok(check, message) = Finding.new(check: check, severity: :ok, message: message, fix: nil)

    # A model to seed the platform default from: DEEPSEEK_MODEL env, else the first
    # configured provider's default. nil when nothing to seed from.
    def seed_model
      Insika::Coercion.presence(@env["DEEPSEEK_MODEL"])
    end
  end
end

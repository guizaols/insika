# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Insika::Doctor do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:settings_store) { Insika::SettingsStore.new(config_store: config_store) }
  let(:llm_provider_store) { Insika::LLMProviderStore.new(config_store: config_store) }

  def doctor(env: {}, **overrides)
    described_class.new(
      env: env, settings_store: settings_store,
      llm_provider_store: llm_provider_store, backend: backend, **overrides
    )
  end

  describe "#run" do
    it "reports env findings from the EnvSchema" do
      report = doctor(env: { "HARNESS_BOGUS" => "1" }).run
      env = report.findings.select { |f| f.check == "env" }
      expect(env.map(&:severity)).to include(:error)
      expect(report).not_to be_ok
    end

    it "a fully-configured deployment is ok? with all green checks" do
      settings_store.update("default_model" => "deepseek-chat")
      llm_provider_store.upsert(api: "deepseek", api_key: "sk-x")
      report = doctor(env: { "ADMIN_TOKEN" => "t" }).run
      expect(report).to be_ok
      expect(report.errors).to be_empty
      # env + settings-schema + default-model + db + llm-provider + admin-token
      expect(report.findings.select(&:ok?).map(&:check)).to include("default-model", "llm-provider", "admin-token")
    end

    it "warns when no platform default_model is set" do
      dm = doctor.run.findings.find { |f| f.check == "default-model" }
      expect(dm.severity).to eq(:warn)
    end

    it "warns when no LLM provider is configured, ok when DEEPSEEK_API_KEY is present" do
      expect(doctor.run.findings.find { |f| f.check == "llm-provider" }.severity).to eq(:warn)
      ok = doctor(env: { "DEEPSEEK_API_KEY" => "sk" }).run.findings.find { |f| f.check == "llm-provider" }
      expect(ok.severity).to eq(:ok)
    end

    it "info (not error) when the backend is ephemeral memory" do
      db = doctor.run.findings.find { |f| f.check == "db" }
      expect(db.severity).to eq(:info)
    end

    it "ok when the backend is durable SQLite" do
      sqlite = Insika::Stores::SQLite.new(path: ":memory:")
      cs = Insika::ConfigStore.new(store: sqlite)
      doc = described_class.new(env: {}, settings_store: Insika::SettingsStore.new(config_store: cs),
                                llm_provider_store: Insika::LLMProviderStore.new(config_store: cs), backend: sqlite)
      expect(doc.run.findings.find { |f| f.check == "db" }.severity).to eq(:ok)
    end

    it "skips store checks when their collaborators are absent (env-only mode)" do
      report = described_class.new(env: {}, backend: nil).run
      checks = report.findings.map(&:check)
      expect(checks).to include("env", "db", "admin-token")
      expect(checks).not_to include("settings-schema", "default-model", "llm-provider")
    end

    it "a crashing check degrades to an error finding (never blows up run)" do
      broken = instance_double(Insika::SettingsStore)
      allow(broken).to receive(:pending_migrations).and_raise(RuntimeError, "boom")
      allow(broken).to receive(:get).and_return({}) # default_model check runs independently
      report = described_class.new(env: {}, settings_store: broken, backend: backend).run
      crash = report.findings.find { |f| f.check == "settings-schema" }
      expect(crash.severity).to eq(:error)
      expect(crash.message).to match(/check crashed.*boom/)
    end
  end

  # A stored tool whose definition stopped building is dropped by the overlay with only
  # a stderr warn — the agent silently loses the tool. This check is that drop's report.
  describe "data tools" do
    let(:tool_store) { Insika::ToolStore.new(config_store: config_store) }

    def store_legacy(name, parameters)
      config_store.put("tools", name, { "definition" => {
                         "name" => name, "description" => "d", "parameters" => parameters,
                         "request" => { "method" => "POST", "url" => "https://a.test", "headers" => {},
                                        "query" => {}, "body" => nil },
                         "response" => { "extract" => "body_raw", "path" => nil },
                         "secret_headers" => [], "side_effect" => true, "timeout" => nil
                       }, "updated_at" => "2026-01-01T00:00:00Z", "history" => [] })
    end

    it "is skipped when no tool_store is injected" do
      expect(doctor.run.findings.map(&:check)).not_to include("data-tools")
    end

    it "ok when every definition builds" do
      store_legacy("ping", [{ "name" => "q", "type" => "string", "required" => true }])
      finding = doctor(tool_store: tool_store).run.findings.find { |f| f.check == "data-tools" }
      expect(finding.severity).to eq(:ok)
      expect(finding.message).to match(/1 data tool/)
    end

    it "errors on a legacy bare `array` param, and offers the lossless spelling as a fix" do
      store_legacy("recommend_products", [{ "name" => "products", "type" => "array", "required" => true }])
      doc = doctor(tool_store: tool_store)
      finding = doc.run.findings.find { |f| f.check == "data-tools" }
      expect(finding.severity).to eq(:error)
      expect(finding.message).to match(/'recommend_products' is dropped from the catalog.*needs an item type/)
      expect(finding).to be_fixable

      _before, after = doc.fix!
      expect(after.findings.find { |f| f.check == "data-tools" }.severity).to eq(:ok)
      expect(tool_store.get("recommend_products")["parameters"])
        .to eq("type" => "object",
               "properties" => { "products" => { "type" => "array", "items" => { "type" => "string" } } },
               "required" => ["products"])
    end

    it "reports a definition it cannot repair without offering a guess" do
      store_legacy("broken", [{ "name" => "Bad Name", "type" => "string" }])
      finding = doctor(tool_store: tool_store).run.findings.find { |f| f.check == "data-tools" }
      expect(finding.severity).to eq(:error)
      expect(finding).not_to be_fixable
    end
  end

  describe "#fix!" do
    it "runs the fixable findings and re-diagnoses to green" do
      # pre-versioning settings record (no schema_version) + no default_model
      config_store.put("settings", "general", { "streaming" => true })
      doc = doctor(env: { "DEEPSEEK_MODEL" => "deepseek-chat" })

      before, after = doc.fix!
      expect(before.fixable.map(&:check)).to contain_exactly("settings-schema", "default-model")

      expect(after.findings.find { |f| f.check == "settings-schema" }.severity).to eq(:ok)
      expect(after.findings.find { |f| f.check == "default-model" }.severity).to eq(:ok)
      expect(settings_store.stored_schema_version).to eq(Insika::SettingsStore::SCHEMA_VERSION)
      expect(settings_store.get["default_model"]).to eq("deepseek-chat")
    end

    it "leaves default_model unfixable when there is no seed source" do
      doc = doctor # no DEEPSEEK_MODEL env
      dm = doc.run.findings.find { |f| f.check == "default-model" }
      expect(dm).not_to be_fixable
    end
  end

  describe "Report rendering" do
    it "to_h is JSON-serializable (no procs leak)" do
      h = doctor.run.to_h
      expect(h).to include("ok", "counts", "findings")
      expect { require "json"; JSON.generate(h) }.not_to raise_error
    end

    it "to_s summarizes errors and warnings" do
      s = doctor(env: { "HARNESS_BOGUS" => "1" }).run.to_s
      expect(s).to match(/error\(s\).*warning\(s\)/)
    end
  end

  describe "soak checks (RFC-0026)" do
    it "soak-envelope: :info when the envelope is absent (not every deployment soaks)" do
      Dir.mktmpdir do |dir|
        finding = described_class.new(env: {}, soak_envelope_path: File.join(dir, "SOAK.md")).run
                                .findings.find { |f| f.check == "soak-envelope" }
        expect(finding.severity).to eq(:info)
      end
    end

    it "soak-envelope: :ok when present and parseable" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "SOAK.md")
        File.write(path, "```yaml\n" \
                         "version: 1\ntarget: staging\nduration_hours: 72\nwarmup_hours: 6\n" \
                         "arrival: poisson\nturns_per_hour: 60\nsession_turns: 7\nconcurrency_cap: 8\n" \
                         "web_concurrency: 1\n" \
                         "rss_growth_ratio: 1.15\nprep_p95_drift_ratio: 1.5\nrestarts_max: 0\n" \
                         "error_rate_ceiling: 0.005\nno_usage_rate_ceiling: 0.002\n" \
                         "coverage_min_ratio: 0.95\ngap_seconds_max: 900\nhourly_turn_floor: 30\n```\n")
        finding = described_class.new(env: {}, soak_envelope_path: path).run
                                .findings.find { |f| f.check == "soak-envelope" }
        expect(finding.severity).to eq(:ok)
      end
    end

    it "soak-envelope: :error when present and broken" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "SOAK.md")
        File.write(path, "# no yaml fence here\n")
        finding = described_class.new(env: {}, soak_envelope_path: path).run
                                .findings.find { |f| f.check == "soak-envelope" }
        expect(finding.severity).to eq(:error)
        expect(finding.message).to match(/no fenced yaml block/)
      end
    end

    it "turn-timing: :info when INSIKA_TURN_TIMING is off, :ok when on" do
      off = described_class.new(env: {}).run.findings.find { |f| f.check == "turn-timing" }
      expect(off.severity).to eq(:info)
      expect(off.message).to match(/soak/)

      on = described_class.new(env: { "INSIKA_TURN_TIMING" => "1" }).run
                         .findings.find { |f| f.check == "turn-timing" }
      expect(on.severity).to eq(:ok)
    end
  end

  # A prompt file holding a serialized object serves a mangled prompt on every turn and
  # nothing else reports it: the file is present, non-empty, and the agent answers.
  describe "prompt-files check" do
    let(:cs) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
    let(:files) { Insika::AgentFileStore.new(config_store: cs) }

    it "flags a file whose content is a serialized entry" do
      files.write("bia", "IDENTITY.md", "# Sou a Bia\n\nOlá.")
      # Written straight to the ConfigStore: the store's own guard refuses this now, so
      # the only way to have it is to have been corrupted BEFORE the guard existed.
      cs.put("agent_files", "loja",
             { "files" => { "TOOLS.md" => { "content" => %({"content" => "# Tools\\n", "history" => []}),
                                            "updated_at" => "2026-07-16T21:48:33Z", "history" => [] } } })

      report = described_class.new(env: {}, agent_file_store: files).run
      finding = report.findings.find { |f| f.check == "prompt-files" }

      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("agent 'loja' file 'TOOLS.md'")
      expect(finding.fixable?).to be(false) # recovering the markdown is not a one-liner
    end

    it "is ok when every file is text" do
      files.write("bia", "IDENTITY.md", "# Sou a Bia")
      finding = described_class.new(env: {}, agent_file_store: files).run
                               .findings.find { |f| f.check == "prompt-files" }
      expect([finding.severity, finding.message]).to eq([:ok, "1 prompt file(s) across 1 agent(s): all text"])
    end

    it "is skipped without the store" do
      expect(described_class.new(env: {}).run.findings.map(&:check)).not_to include("prompt-files")
    end
  end

  # Eagerness moved from the frontmatter to the agent. Both halves of that move fail
  # QUIETLY: a stale `eager:` key stops being honored without anything crashing, and
  # an eager name outside the allowlist is intersected away. This check is the report.
  describe "skill-eager check" do
    let(:cs) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
    let(:skills) { Insika::SkillStore.new(config_store: cs) }
    let(:profiles) { Insika::StoredProfileSource.new(config_store: cs) }

    def skill_md(name, extra = "") = "---\nname: #{name}\ndescription: d\n#{extra}---\n\nbody\n"

    def finding(**over)
      described_class.new(env: {}, **over).run.findings.find { |f| f.check == "skill-eager" }
    end

    it "warns about a skill still declaring eager: in its frontmatter, naming the replacement" do
      skills.write("formato", skill_md("formato", "eager: true\n"))

      f = finding(skill_store: skills)

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("skill 'formato'", "IGNORED", "skills_eager")
    end

    it "does not confuse the word eager in the BODY with the frontmatter key" do
      skills.write("prosa", "---\nname: prosa\ndescription: d\n---\n\nBe eager: help fast.\n")

      expect(finding(skill_store: skills).severity).to eq(:ok)
    end

    it "warns when an agent marks a skill eager that it does not allow" do
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: ["cardapio"],
                                              skills_eager: %w[cardapio formato]))

      f = finding(profile_source: profiles)

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("agent 'loja'", "skill 'formato'", "no-op")
    end

    it "says nothing about an agent whose skills allowlist is nil (everything is allowed)" do
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills_eager: ["formato"]))

      expect(finding(profile_source: profiles).severity).to eq(:ok)
    end

    it "the blanket switch names nothing, so it can name nothing unreachable" do
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: [], skills_eager: true))

      expect(finding(profile_source: profiles).severity).to eq(:ok)
    end

    it "is skipped without either collaborator" do
      expect(described_class.new(env: {}).run.findings.map(&:check)).not_to include("skill-eager")
    end

    # The sweep covers DISK seeds too (via the catalog), not only authored store
    # skills — a stale `eager:` shipped inside a seed pack fails just as quietly.
    it "flags a stale eager: sitting in a disk seed, through the catalog" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "formato"))
        File.write(File.join(root, "formato", "SKILL.md"), skill_md("formato", "eager: true\n"))

        f = finding(skill_catalog: Insika::SkillCatalog.new([root]))

        expect(f.severity).to eq(:warn)
        expect(f.message).to include("skill 'formato'", "IGNORED")
      end
    end
  end

  # Drift between a pack's prose and the catalog. Every input is MECHANICAL — names,
  # allowlists, agent identities — because a check that parses prose false-positives on
  # the first real pack and takes the doctor's credibility with it.
  describe "skill-drift check" do
    let(:cs) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
    let(:skills) { Insika::SkillStore.new(config_store: cs) }
    let(:profiles) { Insika::StoredProfileSource.new(config_store: cs) }
    let(:files) { Insika::AgentFileStore.new(config_store: cs) }

    def skill_md(name, body, extra = "") = "---\nname: #{name}\ndescription: d\n#{extra}---\n\n#{body}\n"

    def findings
      described_class.new(env: {}, skill_store: skills, profile_source: profiles,
                          agent_file_store: files).run.findings.select { |f| f.check == "skill-drift" }
    end

    it "is skipped without both the skills and the profiles" do
      expect(described_class.new(env: {}, skill_store: skills).run.findings.map(&:check)).not_to include("skill-drift")
    end

    # D1 residue. The routing table is generated now, so a hand-written one is pure
    # drift: it instructs the model about a skill the agent cannot load.
    it "flags a prompt file naming a skill outside that agent's allowlist" do
      skills.write("gift-concierge", skill_md("gift-concierge", "b"))
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: []))
      files.write("loja", "SKILLS.md", "| gift-concierge | quando o cliente quer um presente |")

      f = findings.first

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("agent 'loja'", "file 'SKILLS.md'", "skill 'gift-concierge'")
    end

    it "says nothing when the prompt file only names skills the agent allows" do
      skills.write("gift-concierge", skill_md("gift-concierge", "b"))
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: ["gift-concierge"]))
      files.write("loja", "SKILLS.md", "| gift-concierge | presente |")

      expect(findings.map(&:severity)).to eq([:ok])
    end

    # D2. Three shared skills on the pilot each said "na Natura", and the Cacau Show
    # agent was served all three as its own policy.
    it "flags a shared skill whose body names one of its holders" do
      skills.write("escalation", skill_md("escalation", "na Natura a devolucao e em 7 dias"))
      profiles.put(Insika::AgentProfile.build(id: "natura", model: "m", skills: ["escalation"]))
      profiles.put(Insika::AgentProfile.build(id: "cacau", model: "m", skills: ["escalation"]))

      f = findings.find { |x| x.message.include?("shared skill") }

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("shared skill 'escalation'", "'natura'", "Specialize")
    end

    # The finding shrinks as the VICTIMS stop reading: a holder with its own version
    # is no longer served anybody else's text.
    it "clears once the affected holders have specialized" do
      skills.write("escalation", skill_md("escalation", "na Natura, 7 dias"))
      skills.write("escalation", skill_md("escalation", "na Cacau Show"), agent: "cacau")
      profiles.put(Insika::AgentProfile.build(id: "natura", model: "m", skills: ["escalation"]))
      profiles.put(Insika::AgentProfile.build(id: "cacau", model: "m", skills: ["escalation"]))

      expect(findings.map(&:severity)).to eq([:ok])
    end

    # The direction that must NOT clear: specializing the NAMED holder moves natura
    # onto its own copy, but the shared body still says "na Natura" and cacau still
    # reads it — the exact harm the check exists for. Identity comes from all
    # holders; only the readers shrink.
    it "keeps flagging while another holder still reads the body naming the specialized one" do
      skills.write("escalation", skill_md("escalation", "na Natura, 7 dias"))
      skills.write("escalation", skill_md("escalation", "na Natura, 7 dias"), agent: "natura")
      profiles.put(Insika::AgentProfile.build(id: "natura", model: "m", skills: ["escalation"]))
      profiles.put(Insika::AgentProfile.build(id: "cacau", model: "m", skills: ["escalation"]))

      f = findings.find { |x| x.message.include?("shared skill") }

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("'natura'", "cacau")
    end

    it "says nothing when only ONE agent holds the skill (it is not shared)" do
      skills.write("escalation", skill_md("escalation", "na Natura, 7 dias"))
      profiles.put(Insika::AgentProfile.build(id: "natura", model: "m", skills: ["escalation"]))

      expect(findings.map(&:severity)).to eq([:ok])
    end

    # The credibility rule: structural and short tokens are not identity. "store"
    # appears in every retail skill ever written.
    it "does not treat structural tokens of an agent id as identity" do
      skills.write("esc", skill_md("esc", "consulte a politica da store antes de escalar"))
      profiles.put(Insika::AgentProfile.build(id: "store-a", model: "m", skills: ["esc"]))
      profiles.put(Insika::AgentProfile.build(id: "store-b", model: "m", skills: ["esc"]))

      expect(findings.map(&:severity)).to eq([:ok])
    end

    it "reads the display name from metadata, accents folded" do
      skills.write("esc", skill_md("esc", "na Cacau Show a troca e na loja"))
      profiles.put(Insika::AgentProfile.build(id: "a1", model: "m", skills: ["esc"],
                                              metadata: { "name" => "Cacau" }))
      profiles.put(Insika::AgentProfile.build(id: "a2", model: "m", skills: ["esc"]))

      expect(findings.first.message).to include("names 'Cacau'")
    end

    # D3 residue: `companions:` prevents the pair breaking apart, but only where it is
    # declared, and only where the agent can load both halves.
    it "flags a body referencing another catalog skill without declaring it a companion" do
      skills.write("natura-line-expert", skill_md("natura-line-expert", "consulte query-construction antes de buscar"))
      skills.write("query-construction", skill_md("query-construction", "b"))
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: nil))

      f = findings.find { |x| x.message.include?("without declaring") }

      expect(f.message).to include("skill 'natura-line-expert' references skill 'query-construction'",
                                   "companions: [query-construction]")
    end

    it "says nothing once the companion is declared" do
      skills.write("mapa", skill_md("mapa", "consulte query antes de buscar", "companions: [query]\n"))
      skills.write("query", skill_md("query", "b"))
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: nil))

      expect(findings.map(&:severity)).to eq([:ok])
    end

    it "flags a declared companion the agent is not allowed to load" do
      skills.write("mapa", skill_md("mapa", "b", "companions: [query]\n"))
      skills.write("query", skill_md("query", "b"))
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: ["mapa"]))

      f = findings.find { |x| x.message.include?("companion") && x.message.include?("agent 'loja'") }

      expect(f.message).to include("allows skill 'mapa' but not its companion 'query'")
    end

    # The drift checks read DISK seeds too (via the catalog): a Natura-in-shared-body
    # sitting in a seed pack drifts exactly like an authored one.
    it "flags a shared DISK seed naming a holder, with no store record at all" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "escalation"))
        File.write(File.join(root, "escalation", "SKILL.md"), skill_md("escalation", "na Natura, 7 dias"))
        profiles.put(Insika::AgentProfile.build(id: "natura", model: "m", skills: ["escalation"]))
        profiles.put(Insika::AgentProfile.build(id: "cacau", model: "m", skills: ["escalation"]))

        drift = described_class.new(env: {}, skill_catalog: Insika::SkillCatalog.new([root]),
                                    profile_source: profiles, agent_file_store: files).run
                               .findings.select { |f| f.check == "skill-drift" }

        expect(drift.first.severity).to eq(:warn)
        expect(drift.first.message).to include("shared skill 'escalation'", "'natura'")
      end
    end
  end

  # A half-configured relay is the silent kind of broken: one half accepts turns it
  # can never answer, the other mounts nothing at all. Both look fine from outside.
  describe "relay-channel check" do
    def relay_finding(env)
      described_class.new(env: env).run.findings.find { |f| f.check == "relay-channel" }
    end

    it "says nothing when nobody asked for a relay" do
      expect(relay_finding({})).to be_nil
    end

    it "is ok with both halves" do
      finding = relay_finding("INSIKA_RELAY_TOKEN" => "t", "INSIKA_RELAY_DELIVER_URL" => "https://x.example/h")
      expect(finding.severity).to eq(:ok)
    end

    it "warns on a token with no callback — turns are accepted and never answered" do
      finding = relay_finding("INSIKA_RELAY_TOKEN" => "t")
      expect(finding.severity).to eq(:warn)
      expect(finding.message).to include("no reply can be delivered")
    end

    it "warns on a callback with no token — the route is not mounted at all" do
      finding = relay_finding("INSIKA_RELAY_DELIVER_URL" => "https://x.example/h")
      expect(finding.severity).to eq(:warn)
      expect(finding.message).to include("NOT mounted")
    end
  end

  # The widget is the one PUBLIC channel, so its misconfigurations cost money rather
  # than merely failing — and the 503 it answers reads to an operator as "broken"
  # unless something says which half is missing.
  describe "web-widget check" do
    def widget_finding(env, settings: nil)
      described_class.new(env: env, settings_store: settings)
        .run.findings.find { |f| f.check == "web-widget" }
    end

    def settings_with(edge) = Class.new { define_method(:get) { { "edge" => edge } } }.new

    it "says nothing when nobody asked for a widget" do
      expect(widget_finding({})).to be_nil
    end

    it "is ok with both allowlists and a platform rate limit" do
      finding = widget_finding({ "INSIKA_WIDGET_ORIGINS" => "https://shop.example",
                                 "INSIKA_WIDGET_AGENTS" => "support" },
                               settings: settings_with({ "chat_rate_limit" => 6 }))
      expect(finding.severity).to eq(:ok)
    end

    it "warns on either half of the switch, naming the missing one" do
      origins_only = widget_finding({ "INSIKA_WIDGET_ORIGINS" => "https://shop.example" })
      expect(origins_only.severity).to eq(:warn)
      expect(origins_only.message).to include("INSIKA_WIDGET_AGENTS")

      agents_only = widget_finding({ "INSIKA_WIDGET_AGENTS" => "support" })
      expect(agents_only.message).to include("INSIKA_WIDGET_ORIGINS")
    end

    # A per-agent limit still satisfies the gate and the profiles are not readable
    # from here, so this is a warning — but it is the likeliest reason for a 503.
    it "warns on a mount with no platform rate limit — the likeliest cause of a 503" do
      finding = widget_finding({ "INSIKA_WIDGET_ORIGINS" => "https://shop.example",
                                 "INSIKA_WIDGET_AGENTS" => "support" },
                               settings: settings_with({}))
      expect(finding.severity).to eq(:warn)
      expect(finding.message).to include("503")
    end
  end
end


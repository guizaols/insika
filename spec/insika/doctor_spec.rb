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

    # the relay delivery enum is validated like every other env key —
    # a typo'd value is a finding, the two real values are not.
    it "flags an unknown INSIKA_RELAY_DELIVERY, accepts progressive/at_end" do
      bad = doctor(env: { "INSIKA_RELAY_DELIVERY" => "banana" }).run
      env = bad.findings.select { |f| f.check == "env" }
      expect(env.map(&:message).join).to match(/INSIKA_RELAY_DELIVERY must be one of .*progressive/)
      expect(bad).not_to be_ok

      ok = doctor(env: { "INSIKA_RELAY_DELIVERY" => "progressive" }).run
      expect(ok.findings.select { |f| f.check == "env" && f.error? }).to be_empty
      ok2 = doctor(env: { "INSIKA_RELAY_DELIVERY" => "at_end" }).run
      expect(ok2.findings.select { |f| f.check == "env" && f.error? }).to be_empty
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

    it "flags a data-tool in an mcp:* group as a legacy snapshot (RFC-0040 PR2), alongside the ok finding" do
      config_store.put("tools", "search", { "definition" => {
                          "name" => "search", "description" => "d",
                          "parameters" => { "type" => "object", "properties" => {}, "required" => [] },
                          "request" => { "method" => "POST", "url" => "https://a.test", "headers" => {},
                                         "query" => {}, "body" => nil },
                          "response" => { "extract" => "body_raw", "path" => nil },
                          "secret_headers" => [], "side_effect" => true, "timeout" => nil,
                          "group" => "mcp:tavily"
                        }, "updated_at" => "2026-01-01T00:00:00Z", "history" => [] })
      findings = doctor(tool_store: tool_store).run.findings.select { |f| f.check == "data-tools" }

      expect(findings.map(&:severity)).to include(:ok, :info)
      expect(findings.map(&:message).join).to match(/search.*mcp:tavily.*LIVE/)
    end
  end

  describe "mcp check (RFC-0040)" do
    let(:mcp_store) { Insika::McpStore.new(config_store: config_store) }

    it "is skipped when no mcp_store is injected" do
      expect(doctor.run.findings.map(&:check)).not_to include("mcp")
    end

    it "ok when no instance needs attention" do
      mcp_store.upsert("name" => "tavily", "transport" => "http", "url" => "https://x",
                       "headers" => { "Authorization" => "Bearer x" })
      finding = doctor(mcp_store: mcp_store).run.findings.find { |f| f.check == "mcp" }
      expect(finding.severity).to eq(:ok)
    end

    it "warns on an http instance still storing credentials under the pre-RFC-0040 'env'" do
      config_store.put("mcp", "legacy",
                       { "name" => "legacy", "transport" => "http", "url" => "https://x",
                         "env" => { "Authorization" => "Bearer old" }, "enabled" => true })
      findings = doctor(mcp_store: mcp_store).run.findings.select { |f| f.check == "mcp" }
      expect(findings.map(&:severity)).to include(:warn)
      expect(findings.map(&:message).join).to match(/legacy.*'env'.*'headers'/)
    end

    it "flags an enabled stdio instance when INSIKA_MCP_STDIO is not set" do
      mcp_store.upsert("name" => "fs", "transport" => "stdio", "command" => "npx", "enabled" => true)
      findings = doctor(env: {}, mcp_store: mcp_store).run.findings.select { |f| f.check == "mcp" }
      expect(findings.map(&:message).join).to match(/fs.*INSIKA_MCP_STDIO/)

      gated = doctor(env: { "INSIKA_MCP_STDIO" => "1" }, mcp_store: mcp_store).run.findings.select { |f| f.check == "mcp" }
      expect(gated.first.severity).to eq(:ok)
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

  describe "soak checks " do
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

  describe "grounding check (— a matcher that matches nothing is useless)" do
    let(:cs) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
    let(:profiles) { Insika::StoredProfileSource.new(config_store: cs) }

    def finding(**over)
      described_class.new(env: {}, **over).run.findings.find { |f| f.check == "grounding" }
    end

    it "warns when an agent has grounding on but no matcher.sku" do
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m",
                                              grounding: { "mode" => "flag", "matcher" => {} }))

      f = finding(profile_source: profiles)

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("agent 'loja'", "no matcher.sku")
    end

    it "is ok when every grounding agent declares a sku" do
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m",
                                              grounding: { "mode" => "flag",
                                                           "matcher" => { "sku" => "\\d+" } }))

      expect(finding(profile_source: profiles).severity).to eq(:ok)
    end

    it "says nothing about an agent without grounding (the feature is off)" do
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m"))

      expect(finding(profile_source: profiles).severity).to eq(:ok)
    end

    it "is skipped without a profile source" do
      expect(described_class.new(env: {}).run.findings.map(&:check)).not_to include("grounding")
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

    # D2. Three shared skills on a pilot deployment each named one of their
    # holders, and every holder was served all three as its own policy.
    it "flags a shared skill whose body names one of its holders" do
      skills.write("escalation", skill_md("escalation", "na biro a devolucao e em 7 dias"))
      profiles.put(Insika::AgentProfile.build(id: "biro", model: "m", skills: ["escalation"]))
      profiles.put(Insika::AgentProfile.build(id: "kino", model: "m", skills: ["escalation"]))

      f = findings.find { |x| x.message.include?("shared skill") }

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("shared skill 'escalation'", "'biro'", "Specialize")
    end

    # The finding shrinks as the VICTIMS stop reading: a holder with its own version
    # is no longer served anybody else's text.
    it "clears once the affected holders have specialized" do
      skills.write("escalation", skill_md("escalation", "na biro, 7 dias"))
      skills.write("escalation", skill_md("escalation", "na kino a troca e em 3 dias"), agent: "kino")
      profiles.put(Insika::AgentProfile.build(id: "biro", model: "m", skills: ["escalation"]))
      profiles.put(Insika::AgentProfile.build(id: "kino", model: "m", skills: ["escalation"]))

      expect(findings.map(&:severity)).to eq([:ok])
    end

    # The direction that must NOT clear: specializing the NAMED holder moves biro
    # onto its own copy, but the shared body still says "na biro" and kino still
    # reads it — the exact harm the check exists for. Identity comes from all
    # holders; only the readers shrink.
    it "keeps flagging while another holder still reads the body naming the specialized one" do
      skills.write("escalation", skill_md("escalation", "na biro, 7 dias"))
      skills.write("escalation", skill_md("escalation", "na biro, 7 dias"), agent: "biro")
      profiles.put(Insika::AgentProfile.build(id: "biro", model: "m", skills: ["escalation"]))
      profiles.put(Insika::AgentProfile.build(id: "kino", model: "m", skills: ["escalation"]))

      f = findings.find { |x| x.message.include?("shared skill") }

      expect(f.severity).to eq(:warn)
      expect(f.message).to include("'biro'", "kino")
    end

    it "says nothing when only ONE agent holds the skill (it is not shared)" do
      skills.write("escalation", skill_md("escalation", "na biro, 7 dias"))
      profiles.put(Insika::AgentProfile.build(id: "biro", model: "m", skills: ["escalation"]))

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
      skills.write("esc", skill_md("esc", "na Kino a troca e na loja"))
      profiles.put(Insika::AgentProfile.build(id: "a1", model: "m", skills: ["esc"],
                                              metadata: { "name" => "Kino" }))
      profiles.put(Insika::AgentProfile.build(id: "a2", model: "m", skills: ["esc"]))

      expect(findings.first.message).to include("names 'Kino'")
    end

    # D3 residue: `companions:` prevents the pair breaking apart, but only where it is
    # declared, and only where the agent can load both halves.
    it "flags a body referencing another catalog skill without declaring it a companion" do
      skills.write("biro-line-expert", skill_md("biro-line-expert", "consulte query-construction antes de buscar"))
      skills.write("query-construction", skill_md("query-construction", "b"))
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", skills: nil))

      f = findings.find { |x| x.message.include?("without declaring") }

      expect(f.message).to include("skill 'biro-line-expert' references skill 'query-construction'",
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

    # The drift checks read DISK seeds too (via the catalog): a store-specific
    # phrase in a shared seed pack drifts exactly like an authored one.
    it "flags a shared DISK seed naming a holder, with no store record at all" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "escalation"))
        File.write(File.join(root, "escalation", "SKILL.md"), skill_md("escalation", "na biro, 7 dias"))
        profiles.put(Insika::AgentProfile.build(id: "biro", model: "m", skills: ["escalation"]))
        profiles.put(Insika::AgentProfile.build(id: "kino", model: "m", skills: ["escalation"]))

        drift = described_class.new(env: {}, skill_catalog: Insika::SkillCatalog.new([root]),
                                    profile_source: profiles, agent_file_store: files).run
                               .findings.select { |f| f.check == "skill-drift" }

        expect(drift.first.severity).to eq(:warn)
        expect(drift.first.message).to include("shared skill 'escalation'", "'biro'")
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

  # A staging service drifted to WEB_CONCURRENCY=4 with nobody noticing, and a
  # reply leaked across sessions (per-worker FIFO/collect/steer, docs/DEPLOY.md).
  # This check is the only thing that would have caught it before traffic did.
  describe "web-concurrency check" do
    def concurrency_finding(env)
      described_class.new(env: env).run.findings.find { |f| f.check == "web-concurrency" }
    end

    it "is ok when unset (the documented default)" do
      finding = concurrency_finding({})
      expect(finding.severity).to eq(:ok)
    end

    it "is ok at exactly 1" do
      finding = concurrency_finding("WEB_CONCURRENCY" => "1")
      expect(finding.severity).to eq(:ok)
    end

    it "warns above 1 — session semantics are per-worker without sticky routing" do
      finding = concurrency_finding("WEB_CONCURRENCY" => "4")
      expect(finding.severity).to eq(:warn)
      expect(finding.message).to include("WEB_CONCURRENCY=4", "sticky routing")
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

  describe "shadow-parity check " do
    let(:pairs) { Insika::ShadowPairStore.new(store: backend) }
    let(:criterion_path) { File.expand_path("../fixtures/parity/criterion.md", __dir__) }

    def shadow_findings(env, pair_store: nil, settings: nil)
      described_class.new(env: env, settings_store: settings, shadow_pair_store: pair_store)
                     .run.findings.select { |f| f.check == "shadow-parity" }
    end

    def plant_pair(store, created_at: Time.now.utc)
      id = Insika::ShadowPairStore.key_for(channel: "relay", external_id: "5511", event_id: SecureRandom.hex(4))
      store.record_incumbent(id: id, channel: "relay", event_id: id, external_id: "5511",
                             reply: "r", at: created_at)
      store.record_ours(id: id, channel: "relay", agent: "a", session_id: "relay:5511",
                        task_id: "t", event_id: id, inbound: "oi", reply: "ola", criterion_sha: "sha256:x")
    end

    it "says nothing when shadow is off and there are no pairs" do
      expect(shadow_findings({})).to be_empty
    end

    it "remembers the evidence: shadow off + pairs present is an ok with the count" do
      plant_pair(pairs)
      findings = shadow_findings({}, pair_store: pairs)
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).to include("1 pair")
    end

    it "errors when shadow is on and the criterion does not load, naming the path" do
      findings = shadow_findings({ "INSIKA_RELAY_SHADOW" => "1",
                                   "INSIKA_PARITY_CRITERION" => "/nope.md" })
      expect(findings.map(&:severity)).to eq([:error])
      expect(findings.first.message).to include("/nope.md")
    end

    it "is ok with the frozen sha when shadow is on and the criterion loads" do
      findings = shadow_findings({ "INSIKA_RELAY_SHADOW" => "1",
                                   "INSIKA_PARITY_CRITERION" => criterion_path })
      ok_finding = findings.find(&:ok?)
      expect(ok_finding).not_to be_nil
      expect(ok_finding.message).to include("criterion frozen")
    end

    it "warns that the deliver URL is inert in shadow" do
      findings = shadow_findings({ "INSIKA_RELAY_SHADOW" => "1",
                                   "INSIKA_RELAY_DELIVER_URL" => "https://8.8.8.8/hook",
                                   "INSIKA_PARITY_CRITERION" => criterion_path })
      expect(findings.map(&:severity)).to include(:warn)
      expect(findings.find { |f| f.message.include?("INERT") }).not_to be_nil
    end

    it "warns when nobody is configured to judge" do
      findings = shadow_findings({ "INSIKA_RELAY_SHADOW" => "1",
                                   "INSIKA_PARITY_CRITERION" => criterion_path },
                                 settings: settings_store)
      expect(findings.map(&:severity)).to include(:warn)
      expect(findings.find { |f| f.message.include?("judges") }).not_to be_nil
    end

    it "warns when the oldest pair is older than 2 × window_days — shadow is not permanent" do
      plant_pair(pairs, created_at: Time.now.utc - 30 * 86_400)
      findings = shadow_findings({ "INSIKA_RELAY_SHADOW" => "1",
                                   "INSIKA_PARITY_CRITERION" => criterion_path },
                                 pair_store: pairs)
      expect(findings.find { |f| f.message.include?("not a permanent mode") }).not_to be_nil
    end
  end

  describe "check_cache_layers " do
    BUILTINS = [
      Insika::Context::Providers::Request, Insika::Context::Providers::Prompt,
      Insika::Context::Providers::Skill, Insika::Context::Providers::SkillTrigger,
      Insika::Context::Providers::ToolSearch, Insika::Context::Providers::Memory,
      Insika::Context::Providers::Session
    ].freeze

    def layers_finding
      doctor(context_providers: BUILTINS).run.findings.find { |f| f.check == "cache-layers" }
    end

    it "the builtin set passes (identity partition verified)" do
      expect(layers_finding.severity).to eq(:ok)
    end

    it "a custom provider declaring :identity is a warn (purity unverifiable)" do
      custom = Class.new(Insika::ContextProvider) do
        def layer = :identity
      end
      finding = doctor(context_providers: [custom]).run.findings.find { |f| f.check == "cache-layers" }
      expect(finding.severity).to eq(:warn)
      expect(finding.message).to include("not engine-verified")
    end

    it "a custom provider that EXPLICITLY declares :volatile — the conservative thing — is not flagged" do
      conservative = Class.new(Insika::ContextProvider) do
        def layer = :volatile
      end
      findings = doctor(context_providers: [conservative]).run.findings.select { |f| f.check == "cache-layers" }
      expect(findings.map(&:severity)).to eq([:ok])
    end

    it "works the same with provider INSTANCES (the deployment passes instances)" do
      instance = Class.new(Insika::ContextProvider) do
        def layer = :identity
      end.new
      finding = doctor(context_providers: [instance]).run.findings.find { |f| f.check == "cache-layers" }
      expect(finding.severity).to eq(:warn)
    end

    it "an engine-known volatile provider overriding to :identity is an error (guaranteed cache kill)" do
      rogue = Class.new(Insika::Context::Providers::Memory) do
        def layer = :identity
      end
      finding = doctor(context_providers: [rogue]).run.findings.find { |f| f.check == "cache-layers" }
      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("engine-known turn-dependent")
    end

    it "a provider without layer (never learned the contract) is not flagged" do
      plain = Class.new(Insika::ContextProvider) do
        undef_method(:layer)
        def id = "Custom"
      end
      findings = doctor(context_providers: [plain]).run.findings.select { |f| f.check == "cache-layers" }
      expect(findings.map(&:severity)).to eq([:ok])
    end

    it "collaborator nil -> the check is absent from the report" do
      expect(doctor.run.findings.select { |f| f.check == "cache-layers" }).to be_empty
    end
  end

  describe "memory scopes " do
    let(:memory_store) { Insika::MemoryStore.new(store: Insika::Stores::Memory.new) }

    # A bare cell is the DESIGNED single-tenant customer shape — warning would
    # flag what the engine itself writes, with no tenant to migrate to.
    it "a bare cell in single_tenant (the default) -> ok, never a warn" do
      memory_store.put_fact(tenant: nil, customer: "c-1", key: "k", value: "v")
      finding = doctor(memory_store: memory_store).run.findings.find { |f| f.check == "memory-scopes" }
      expect(finding.severity).to eq(:ok)
      expect(finding.fix).to be_nil
    end

    it "a bare cell in multi_tenant -> warn (unscoped customer memory), never auto-fixed" do
      memory_store.put_fact(tenant: nil, customer: "c-1", key: "k", value: "v")
      finding = doctor(env: { "INSIKA_TENANCY" => "multi_tenant" }, memory_store: memory_store)
                .run.findings.find { |f| f.check == "memory-scopes" }
      expect(finding.severity).to eq(:warn)
      expect(finding.message).to include("unscoped")
      expect(finding.fix).to be_nil
    end

    it "_default + a scoped [tenant:]customer cell -> ok in both tenancies" do
      memory_store.put_fact(tenant: nil, key: "k", value: "v")
      memory_store.put_fact(tenant: "acme", customer: "c-1", key: "k", value: "v")
      finding = doctor(memory_store: memory_store).run.findings.find { |f| f.check == "memory-scopes" }
      expect(finding.severity).to eq(:ok)
      expect(finding.message).to include("all scoped")

      multi = doctor(env: { "INSIKA_TENANCY" => "multi_tenant" }, memory_store: memory_store)
              .run.findings.find { |f| f.check == "memory-scopes" }
      expect(multi.severity).to eq(:ok)
    end

    it "the engine's per-SESSION cells (memory:chat:<id>) never warn, in any tenancy" do
      memory_store.put_fact(tenant: "chat:s-1", key: "k", value: "v")
      finding = doctor(env: { "INSIKA_TENANCY" => "multi_tenant" }, memory_store: memory_store)
                .run.findings.find { |f| f.check == "memory-scopes" }
      expect(finding.severity).to eq(:ok)
    end

    it "in multi_tenant a bare cell matching agent_ids -> ok (the agent-memory tab's cells are excused)" do
      memory_store.put_fact(tenant: nil, customer: "agent-1", key: "k", value: "v")
      finding = doctor(env: { "INSIKA_TENANCY" => "multi_tenant" },
                       memory_store: memory_store, agent_ids: ["agent-1"])
                .run.findings.find { |f| f.check == "memory-scopes" }
      expect(finding.severity).to eq(:ok)
    end

    it "collaborator nil -> the check is absent from the report" do
      expect(doctor.run.findings.select { |f| f.check == "memory-scopes" }).to be_empty
    end
  end

  describe "funnel declarations " do
    let(:funnel_store) { Insika::FunnelStore.new(store: Insika::Stores::Memory.new) }
    let(:outcome_store) { Insika::OutcomeStore.new(store: Insika::Stores::Memory.new) }
    let(:valid_decl) do
      { "stages" => %w[greeted qualified cart paid],
        "advance_on" => { "qualified" => "qualified", "pix_paid" => "paid" },
        "primary" => "paid", "attribution_window" => "72h" }
    end

    def profiles_with(*agents)
      hash = agents.to_h { |a| [a[:id], Insika::AgentProfile.build(id: a[:id], model: "m",
                                                                   funnel: a[:funnel])] }
      Insika::StaticProfileSource.new(hash)
    end

    def funnel_findings(profile_source: nil, funnel: funnel_store, outcomes: outcome_store)
      doctor(profile_source: profile_source, funnel_store: funnel,
             outcome_store: outcomes).run.findings.select { |f| f.check == "outcome-funnel" }
    end

    it "a valid declaration -> a single ok naming stages/primary/window" do
      profiles = profiles_with({ id: "store-support", funnel: valid_decl })
      findings = funnel_findings(profile_source: profiles)
      expect(findings.size).to eq(1)
      expect(findings.first.severity).to eq(:ok)
      expect(findings.first.message).to include("store-support")
      expect(findings.first.message).to include("4 stages")
      expect(findings.first.message).to include("primary 'paid'")
      expect(findings.first.message).to include("72h")
    end

    it "each malformed shape -> an error naming the field" do
      profiles = profiles_with(
        { id: "a", funnel: { "stages" => [], "advance_on" => {}, "primary" => "x" } },
        { id: "b", funnel: { "stages" => %w[x y], "advance_on" => { "k" => "z" },
                             "primary" => "y", "attribution_window" => "nope" } }
      )
      findings = funnel_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:error, :error])
      expect(findings[0].message).to match(/agent 'a'/)
      expect(findings[0].message).to match(/stages/)
      expect(findings[1].message).to match(/agent 'b'/)
      expect(findings[1].message).to match(/advance_on|attribution_window/)
    end

    it "outcomes-without-funnel -> warn (nothing folds — the funnel shows the hole)" do
      profiles = profiles_with({ id: "store-support", funnel: nil })
      outcome_store.create(tenant: "acme", agent: "store-support", outcome: "conversion")
      outcome_store.create(tenant: "acme", agent: "store-support", outcome: "deflected")

      findings = funnel_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:warn])
      expect(findings.first.message).to include("2 outcomes")
      expect(findings.first.message).to include("no funnel")
    end

    it "primary never observed over the folded days -> info" do
      profiles = profiles_with({ id: "store-support", funnel: valid_decl })
      funnel_store.add(tenant: "acme", agent: "store-support",
                       at: Time.iso8601("2026-08-14T10:00:00Z"),
                       counts: { "greeted" => 5, "qualified" => 3 })

      info = funnel_findings(profile_source: profiles).find { |f| f.severity == :info }
      expect(info).not_to be_nil
      expect(info.message).to include("'paid' was never observed")
    end

    it ">= 28 folded days without a baseline -> info (read it)" do
      profiles = profiles_with({ id: "store-support", funnel: valid_decl })
      30.times do |i|
        funnel_store.add(tenant: "acme", agent: "store-support",
                         at: Time.utc(2026, 7, 1 + i, 10), counts: { "greeted" => 1, "paid" => 1 })
      end

      info = funnel_findings(profile_source: profiles).find { |f| f.severity == :info }
      expect(info).not_to be_nil
      expect(info.message).to include("no baseline frozen")
    end

    it "a baseline exists -> no info about freezing" do
      profiles = profiles_with({ id: "store-support", funnel: valid_decl })
      30.times do |i|
        funnel_store.add(tenant: "acme", agent: "store-support",
                         at: Time.utc(2026, 7, 1 + i, 10), counts: { "greeted" => 1, "paid" => 1 })
      end
      funnel_store.set_baseline(tenant: "acme", agent: "store-support",
                                record: { "frozen_at" => "2026-08-01" })

      findings = funnel_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:ok])
    end

    it "both collaborators nil -> declarations only, nothing raises" do
      profiles = profiles_with({ id: "store-support", funnel: valid_decl })
      report = doctor(profile_source: profiles).run
      findings = report.findings.select { |f| f.check == "outcome-funnel" }
      expect(findings.map(&:severity)).to eq([:ok])
    end

    it "no profile_source -> nothing reported" do
      expect(funnel_findings).to be_empty
    end
  end

  describe "follow-up " do
    let(:fu_backend) { Insika::Stores::Memory.new }
    let(:followup_store) { Insika::FollowupStore.new(store: fu_backend) }
    let(:contact_store) { Insika::ContactStore.new(store: fu_backend) }
    let(:valid_decl) do
      { "arm" => "schedule",
        "policy" => { "quiet_hours" => { "timezone" => "America/Sao_Paulo",
                                         "start" => "21:30", "end" => "09:00" },
                      "max_frequency" => "2/24h",
                      "cancel_keywords" => ["não quero mais contato"],
                      "silence_after_sends" => 3 } }
    end

    def profiles_with(*agents)
      hash = agents.to_h { |a| [a[:id], Insika::AgentProfile.build(id: a[:id], model: "m",
                                                                   followup: a[:followup])] }
      Insika::StaticProfileSource.new(hash)
    end

    def followup_findings(profile_source: nil, followup: followup_store, contacts: contact_store)
      doctor(profile_source: profile_source, followup_store: followup,
             contact_store: contacts).run.findings.select { |f| f.check == "follow-up" }
    end

    it "a valid declaration -> a single ok naming arm/quiet hours/keywords" do
      profiles = profiles_with({ id: "store-support", followup: valid_decl })
      findings = followup_findings(profile_source: profiles)
      expect(findings.size).to eq(1)
      expect(findings.first.severity).to eq(:ok)
      expect(findings.first.message).to include("store-support")
      expect(findings.first.message).to include("arm schedule")
      expect(findings.first.message).to include("21:30-09:00")
      expect(findings.first.message).to include("1 keyword(s)")
    end

    it "each malformed shape -> an error naming the defect (D9)" do
      profiles = profiles_with(
        { id: "a", followup: { "arm" => "x", "policy" => { "max_frequency" => "2/3w" } } },
        { id: "b", followup: { "arm" => "y", "policy" => { "quiet_hours" => { "start" => "9" } } } }
      )
      findings = followup_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq(%i[error error])
      expect(findings[0].message).to include("max_frequency")
      expect(findings[1].message).to include("timezone")
    end

    it "a pending record past one claim window of its at -> warn (the tick will never fire it)" do
      # no quiet hours — deterministic whatever the wall clock says (a
      # quiet-hours deferral is EXCLUDED by design: it still fires next pass)
      no_quiet = { "arm" => "schedule", "policy" => { "max_frequency" => "2/24h" } }
      profiles = profiles_with({ id: "store-support", followup: no_quiet })
      now = Time.now.utc
      followup_store.create(tenant: "acme", agent: "store-support", customer: "c-1",
                            session_id: "s-1", at: now + 3600, reason: "r", arm: "schedule",
                            id: "z", now: now) # due in the future — no warn
      findings = followup_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:ok])

      # a record whose `at` has LONG passed while still pending
      fu_backend.set("followups", "acme:store-support:c-1:#{(now - 86_400).iso8601}:zombie",
                  { "id" => "zombie", "tenant" => "acme", "agent" => "store-support",
                    "customer" => "c-1", "session_id" => "s-1",
                    "at" => (now - 86_400).iso8601, "reason" => "r", "arm" => "schedule",
                    "status" => "pending", "task_id" => nil, "blocked_reason" => nil,
                    "transport" => "channel:whatsapp", "created_at" => now.iso8601,
                    "updated_at" => now.iso8601, "fired_at" => nil })
      findings = followup_findings(profile_source: profiles)
      warn = findings.find { |f| f.severity == :warn }
      expect(warn).not_to be_nil
      expect(warn.message).to include("past their scheduled time")
    end

    it "a quiet-hours deferral is NOT a stale-pending warn (it still fires next pass)" do
      decl = { "arm" => "schedule",
               "policy" => { "quiet_hours" => { "timezone" => "UTC",
                                                "start" => "00:00", "end" => "23:59" } } }
      profiles = profiles_with({ id: "store-support", followup: decl })
      now = Time.now.utc
      fu_backend.set("followups", "acme:store-support:c-1:#{(now - 86_400).iso8601}:deferred",
                     { "id" => "deferred", "tenant" => "acme", "agent" => "store-support",
                       "customer" => "c-1", "session_id" => "s-1",
                       "at" => (now - 86_400).iso8601, "reason" => "r", "arm" => "schedule",
                       "status" => "pending", "task_id" => nil, "blocked_reason" => nil,
                       "transport" => "channel:whatsapp", "created_at" => now.iso8601,
                       "updated_at" => now.iso8601, "fired_at" => nil })
      findings = followup_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:ok]) # no warn — a deferral, not a zombie
    end

    it "revoked contact cells -> an info naming the tenant" do
      profiles = profiles_with({ id: "store-support", followup: valid_decl })
      contact_store.set_revoked(tenant: "acme", customer: "c-1")
      contact_store.set_granted(tenant: "acme", customer: "c-2")

      findings = followup_findings(profile_source: profiles)
      info = findings.find { |f| f.severity == :info }
      expect(info).not_to be_nil
      expect(info.message).to include("1 revoked contact cell(s)")
      expect(info.message).to include("acme")
    end

    it "a bare install reports nothing (no follow-up vocabulary)" do
      expect(followup_findings(profile_source: Insika::StaticProfileSource.new)).to be_empty
    end

    it "collaborators nil -> declarations only, nothing raises" do
      profiles = profiles_with({ id: "store-support", followup: valid_decl })
      findings = doctor(profile_source: profiles).run.findings.select { |f| f.check == "follow-up" }
      expect(findings.map(&:severity)).to eq([:ok])
    end
  end

  describe "recurring schedules " do
    let(:s_backend) { Insika::Stores::Memory.new }
    let(:schedule_store) { Insika::ScheduleStore.new(store: s_backend) }

    def sched_profiles_with(*agents)
      hash = agents.to_h { |a| [a[:id], Insika::AgentProfile.build(id: a[:id], model: "m",
                                                                   schedules: a[:schedules])] }
      Insika::StaticProfileSource.new(hash)
    end

    def schedule_findings(profile_source: nil, schedule: schedule_store)
      doctor(profile_source: profile_source, schedule_store: schedule)
        .run.findings.select { |f| f.check == "schedules" }
    end

    it "a valid declaration -> a single ok naming the trigger and the session mode" do
      profiles = sched_profiles_with({ id: "reporter", schedules: [{ "id" => "daily",
                                                                     "cron" => "0 22 * * *",
                                                                     "tz" => "America/Sao_Paulo",
                                                                     "message" => "run" }] })
      findings = schedule_findings(profile_source: profiles)
      expect(findings.size).to eq(1)
      expect(findings.first.severity).to eq(:ok)
      expect(findings.first.message).to include("reporter")
      expect(findings.first.message).to include("cron 0 22 * * *")
      expect(findings.first.message).to include("new session per run")
    end

    it "each malformed shape -> an error naming the defect" do
      profiles = sched_profiles_with(
        { id: "a", schedules: [{ "id" => "x", "cron" => "0 22 * *", "message" => "m" }] },
        { id: "b", schedules: [{ "id" => "y", "every" => 60, "message" => "m",
                                 "tz" => "Mars/Olympus" }] },
        { id: "c", schedules: [{ "id" => "z", "every" => 60, "message" => "", "tz" => "UTC" }] },
        { id: "d", schedules: [{ "id" => "w", "every" => 60, "message" => "m",
                                 "overrides" => { "spawn_rockets" => 9 } }] }
      )
      findings = schedule_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq(%i[error error error error])
      expect(findings[0].message).to include("5 fields")
      expect(findings[1].message).to include("timezone")
      expect(findings[2].message).to include("message")
      expect(findings[3].message).to include("overrides")
    end

    it "an every-interval declaration passes too" do
      profiles = sched_profiles_with({ id: "pulse", schedules: [{ "id" => "hb",
                                                                  "every" => 86_400,
                                                                  "message" => "ping" }] })
      findings = schedule_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).to include("every 86400s")
    end

    it "an `every` shorter than the claim window warns (the cadence floor)" do
      profiles = sched_profiles_with({ id: "pulse", schedules: [{ "id" => "hb",
                                                                  "every" => 60,
                                                                  "message" => "ping" }] })
      findings = schedule_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:warn])
      expect(findings.first.message).to include("every 60s")
      expect(findings.first.message).to include("300s claim window")
    end

    it "a recorded skip on the row -> an info naming reason and time" do
      profiles = sched_profiles_with({ id: "reporter", schedules: [{ "id" => "daily",
                                                                     "every" => 60,
                                                                     "message" => "run" }] })
      now = Time.iso8601("2026-08-19T14:00:00Z")
      schedule_store.sync_declared(tenant: "platform", agent: "reporter",
                                   schedules: [{ "id" => "daily", "every" => 60,
                                                 "message" => "run" }], now: now)
      schedule_store.mark_skip(id: "daily", tenant: "platform", agent: "reporter",
                               reason: :budget, next_fire_at: now + 3600, now: now)
      findings = schedule_findings(profile_source: profiles)
      info = findings.find { |f| f.severity == :info }
      expect(info).not_to be_nil
      expect(info.message).to include("SKIPPED")
      expect(info.message).to include("budget")
    end

    it "a bare install reports nothing (no schedule vocabulary)" do
      expect(schedule_findings(profile_source: Insika::StaticProfileSource.new)).to be_empty
    end

    it "a nil schedule_store -> declarations only, nothing raises" do
      profiles = sched_profiles_with({ id: "reporter", schedules: [{ "id" => "d",
                                                                     "every" => 86_400,
                                                                     "message" => "m" }] })
      findings = doctor(profile_source: profiles).run.findings.select { |f| f.check == "schedules" }
      expect(findings.map(&:severity)).to eq([:ok])
    end
  end

  describe "distillation " do
    let(:p_backend) { Insika::Stores::Memory.new }
    let(:proposal_store) { Insika::ProposalStore.new(store: p_backend) }

    def profiles_with(*agents)
      hash = agents.to_h { |a| [a[:id], Insika::AgentProfile.build(id: a[:id], model: "m",
                                                                   distill: a[:distill])] }
      Insika::StaticProfileSource.new(hash)
    end

    def distill_findings(profile_source: nil, proposals: proposal_store)
      doctor(profile_source: profile_source, proposal_store: proposals)
        .run.findings.select { |f| f.check == "distill" }
    end

    it "a declared distiller with a resolvable model -> ok naming the agent" do
      settings_store.update("utility_model" => "deepseek-v4-flash")
      profiles = profiles_with({ id: "store-support", distill: { "enabled" => true } })
      findings = distill_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).to include("store-support")
      expect(findings.first.message).to include("distillation declared")
    end

    it "an explicit distill.model resolves without the platform utility_model" do
      profiles = profiles_with({ id: "store-support",
                                 distill: { "enabled" => true, "model" => "custom" } })
      expect(distill_findings(profile_source: profiles).map(&:severity)).to eq([:ok])
    end

    it "declared but with NO model slot (neither distill.model nor utility_model) -> warn" do
      profiles = profiles_with({ id: "store-support", distill: { "enabled" => true } })
      findings = distill_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:warn])
      expect(findings.first.message).to include("no model slot")
    end

    it "an explicit enabled: false is a declaration the doctor does not warn on" do
      profiles = profiles_with({ id: "store-support",
                                 distill: { "enabled" => false } })
      expect(distill_findings(profile_source: profiles).map(&:severity)).to eq([:ok])
    end

    it "the ok carries the proposal counts from the store" do
      settings_store.update("utility_model" => "deepseek-v4-flash")
      profiles = profiles_with({ id: "store-support", distill: { "enabled" => true } })
      proposal_store.create(tenant: "acme", customer: "c-1", session_ref: "s",
                            key: "size", value: "M", id: "p1")
      stale = proposal_store.create(tenant: "acme", customer: "c-1", session_ref: "s",
                                    key: "budget", value: "100", id: "p2")
      proposal_store.mark_stale(id: stale.id, current_value: "50")

      findings = distill_findings(profile_source: profiles)
      expect(findings.first.message).to include("1 proposal(s) pending")
      expect(findings.first.message).to include("1 stale")
    end

    it "a bare install (no agent declares distill) -> ok, off" do
      findings = distill_findings(profile_source: Insika::StaticProfileSource.new)
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).to include("distillation off")
    end

    it "nil collaborators -> declarations only, nothing raises" do
      settings_store.update("utility_model" => "deepseek-v4-flash")
      profiles = profiles_with({ id: "store-support", distill: { "enabled" => true } })
      findings = doctor(profile_source: profiles).run.findings.select { |f| f.check == "distill" }
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).not_to include("pending")
    end

    it "no profile_source -> nothing reported" do
      expect(distill_findings).to be_empty
    end
  end

  describe "harvest " do
    let(:p_backend) { Insika::Stores::Memory.new }
    let(:harvest_store) { Insika::HarvestStore.new(store: p_backend) }

    def harvest_profiles(*agents)
      hash = agents.to_h do |a|
        [a[:id], Insika::AgentProfile.build(id: a[:id], model: "m",
                                            harvest: a[:harvest], grounding: a[:grounding])]
      end
      Insika::StaticProfileSource.new(hash)
    end

    def harvest_findings(profile_source: nil, store: harvest_store, criterion: nil)
      doctor(profile_source: profile_source, harvest_store: store, harvest_criterion: criterion)
        .run.findings.select { |f| f.check == "harvest" || f.check == "harvest-criterion" }
    end

    def declared(extra = {})
      { "enabled" => true, "miner" => { "model" => "deepseek-v4-flash" } }.merge(extra)
    end

    let(:grounded) { { "mode" => "enforce", "matcher" => { "sku" => '\bSKU\d{4}\b' } } }

    it "declared with a resolvable model + matcher -> ok naming the agent and the counts" do
      settings_store.update("utility_model" => "deepseek-v4-flash")
      profiles = harvest_profiles({ id: "store-support", harvest: { "enabled" => true },
                                    grounding: grounded })
      cand = harvest_store.create_candidate(
        run_id: "r1", agent: "store-support", name: "s", description: "d", body: "b",
        rationale: "r", origin: ["acme:s"], proposer: "m"
      )
      harvest_store.attach_gate(cand.id, eval_gate: { "passed" => true },
                                        conversion_gate: { "passed" => true },
                                        criterion_sha: "sha")
      harvest_store.mark_awaiting(cand.id)
      findings = harvest_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).to include("store-support")
      expect(findings.first.message).to include("1 awaiting, 0 pending")
    end

    it "declared but with NO model slot -> warn (mining will never run)" do
      profiles = harvest_profiles({ id: "store-support", harvest: { "enabled" => true },
                                    grounding: grounded })
      findings = harvest_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:warn, :ok])
      expect(findings.first.message).to include("no model slot")
    end

    it "enabled without a grounding matcher -> warn (D3: nothing mines)" do
      settings_store.update("utility_model" => "deepseek-v4-flash")
      profiles = harvest_profiles({ id: "store-support", harvest: { "enabled" => true } })
      findings = harvest_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to eq([:warn, :ok])
      expect(findings.first.message).to include("product claims cannot be verified")
    end

    it "a malformed negative_list -> error naming the defect (D4)" do
      settings_store.update("utility_model" => "deepseek-v4-flash")
      profiles = harvest_profiles({ id: "store-support", harvest: declared("negative_list" => [{ "pattern" => "x" }]),
                                    grounding: grounded })
      findings = harvest_findings(profile_source: profiles)
      expect(findings.map(&:severity)).to include(:error)
      expect(findings.find { |f| f.severity == :error }.message).to include("malformed")
    end

    it "a bare install -> ok, off" do
      findings = harvest_findings(profile_source: Insika::StaticProfileSource.new)
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).to include("harvest off")
    end

    it "the criterion line renders; a criterion file that moved warns" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        path = File.join(dir, "CRITERION.md")
        File.write(path, <<~MD)
          # c

          ```yaml
          version: 1
          metric: primary
          window: 72h
          threshold: 0.05
          min_span: 28d
          ```
        MD
        criterion = Insika::Harvest::Criterion.load(path)
        ok = harvest_findings(profile_source: Insika::StaticProfileSource.new, criterion: criterion)
        expect(ok.find { |f| f.check == "harvest-criterion" }.message).to include("sha256:")

        File.write(path, "# edited, no block\n")
        moved = harvest_findings(profile_source: Insika::StaticProfileSource.new, criterion: criterion)
        expect(moved.find { |f| f.check == "harvest-criterion" && f.severity == :warn }).to_not be_nil
      end
    end

    it "nil collaborators -> declarations only, nothing raises" do
      settings_store.update("utility_model" => "deepseek-v4-flash")
      profiles = harvest_profiles({ id: "store-support", harvest: { "enabled" => true },
                                    grounding: grounded })
      findings = harvest_findings(profile_source: profiles, store: nil, criterion: nil)
      expect(findings.map(&:severity)).to eq([:ok])
      expect(findings.first.message).not_to include("awaiting")
    end

    it "no profile_source -> nothing reported" do
      expect(harvest_findings).to be_empty
    end
  end


  describe "check_guardrail_corpora (— the boot gate)" do
    let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }

    it "a malformed corpora declaration is an :error finding — the doctor, not the turn, surfaces it" do
      profiles.put(Insika::AgentProfile.build(id: "typo", model: "m",
                                              guardrails: { "corpora" => { "languages" => ["es"] } }))
      report = doctor(profile_source: profiles).run
      f = report.findings.find { |x| x.check == "guardrail-corpora" }
      expect(f.severity).to eq(:error)
      expect(f.message).to include("typo").and include("es")
    end

    it "a broken pattern source is an :error finding too" do
      profiles.put(Insika::AgentProfile.build(id: "badpat", model: "m",
                                              guardrails: { "corpora" => { "extra" => { "abuse" => ["(unclosed"] } } }))
      report = doctor(profile_source: profiles).run
      f = report.findings.find { |x| x.check == "guardrail-corpora" }
      expect(f.severity).to eq(:error)
      expect(f.message).to include("(unclosed")
    end

    it "ok when every declaration compiles" do
      profiles.put(Insika::AgentProfile.build(id: "fine", model: "m",
                                              guardrails: { "corpora" => { "languages" => ["en"] } }))
      report = doctor(profile_source: profiles).run
      f = report.findings.find { |x| x.check == "guardrail-corpora" }
      expect(f.severity).to eq(:ok)
    end

    it "no profile_source -> nothing reported" do
      expect(doctor.run.findings.select { |f| f.check == "guardrail-corpora" }).to be_empty
    end
  end

  describe "#domain (— the declared-domain inventory)" do
    let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
    let(:tool_store) { Insika::ToolStore.new(config_store: config_store) }

    # E2a — the "bare boot": a fresh install with NO agents names none.
    # (An install that boots an agent reports the built-in pt-BR corpus as
    # source "gem-default" — the removability surface, not a store; see the
    # "no metadata domain" example below.)
    it "E2a — a bare boot names no artifacts (empty report, count 0)" do
      report = doctor(profile_source: Insika::StaticProfileSource.new, tool_store: tool_store).domain
      expect(report).to be_empty
      expect(report.count).to eq(0)
      expect(report.to_h["count"]).to eq(0)
      expect(report.to_h["entries"]).to eq([])
    end

    it "E2b — a pilot enumerates every declared artifact with its source" do
      profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m",
                                              metadata: { "domain" => "e-commerce-pt-BR" }))
      profiles.put(Insika::AgentProfile.build(id: "store-support-guarded", model: "m",
                                              guardrails: { "input" => true }))
      profiles.put(Insika::AgentProfile.build(id: "with-funnel", model: "m",
                                              funnel: { "stages" => %w[greeted cart paid], "primary" => "paid" }))
      tool_store.write({ name: "search_products", description: "search the catalog",
                 request: { url: "https://api.example.com/products", method: "GET" },
                 evidence: { kind: "sku" } })

      report = doctor(profile_source: profiles, tool_store: tool_store).domain
      entries = report.to_h["entries"]

      # persona(1) + guardrail-corpus(3) + safe-responses(3 — every guardrails-on
      # agent also runs the built-in pt-BR replies) + funnel(1) + evidence(1)
      expect(entries.length).to eq(9)

      persona = entries.find { |e| e["kind"] == "persona" }
      expect(persona).to include("agent" => "store-support", "detail" => "domain=e-commerce-pt-BR",
                                 "source" => "deployment")

      corpus = entries.find { |e| e["kind"] == "guardrail-corpus" && e["agent"] == "store-support-guarded" }
      expect(corpus).to include("agent" => "store-support-guarded",
                                "detail" => "languages=pt-BR,en", "source" => "gem-default")
      expect(corpus["how_to_clear"]).to include("docs/domain.md")

      funnel = entries.find { |e| e["kind"] == "funnel" }
      expect(funnel).to include("agent" => "with-funnel",
                                "detail" => "stages=greeted,cart,paid, primary=paid",
                                "source" => "deployment")

      evidence = entries.find { |e| e["kind"] == "evidence" }
      expect(evidence).to include("detail" => "search_products: sku", "source" => "deployment")
      expect(evidence).not_to have_key("agent") # nil compacted
      expect(evidence.keys).not_to include("how_to_clear") # compact
    end

    it "an agent with no metadata domain contributes no persona entry" do
      profiles.put(Insika::AgentProfile.build(id: "plain", model: "m"))
      entries = doctor(profile_source: profiles, tool_store: tool_store).domain.to_h["entries"]
      expect(entries.select { |e| e["kind"] == "persona" }).to be_empty
      # the default guardrails ARE on (the conservative default) — its corpus +
      # safe-reply entries are the gem-default half of the report, not a persona
      expect(entries.map { |e| e["kind"] }).to eq(%w[guardrail-corpus safe-responses])
    end

    it "guardrails-off agents contribute nothing; an EN-only corpus still reports the pt-BR safe replies in effect" do
      profiles.put(Insika::AgentProfile.build(id: "off", model: "m", guardrails: { "input" => false, "output" => false }))
      profiles.put(Insika::AgentProfile.build(id: "cleared", model: "m",
                                              guardrails: { "corpora" => { "languages" => ["en"] } }))
      report = doctor(profile_source: profiles, tool_store: tool_store).domain
      entries = report.to_h["entries"]
      # the EN-only agent cleared the corpus but NOT the pt-BR fallback replies —
      # the doctor's whole point is naming what is still in effect
      expect(entries).to eq([{ "kind" => "safe-responses", "agent" => "cleared",
                               "detail" => "categories=injection,sexual,abuse,escalate,default",
                               "source" => "gem-default",
                               "how_to_clear" => "docs/domain.md#guardrails" }])
    end

    it "the built-in safe-reply entry appears only while a category still falls back to DEFAULTS" do
      partial = Insika::AgentProfile.build(id: "partial", model: "m",
                                           guardrails: { "responses" => { "injection" => "Custom." } })
      full = Insika::AgentProfile.build(id: "full", model: "m",
                                        guardrails: { "responses" => { "default" => "Tudo resolvido." } })
      profiles.put(partial)
      profiles.put(full)

      report = doctor(profile_source: profiles, tool_store: tool_store).domain
      entries = report.to_h["entries"]
      fallback = entries.select { |e| e["kind"] == "safe-responses" }
      expect(fallback.length).to eq(1)
      expect(fallback.first["agent"]).to eq("partial")
      expect(fallback.first["detail"]).to match(/sexual,abuse,escalate,default/) # the 4 still built-in
      expect(fallback.first["source"]).to eq("gem-default")
    end

    it "a raising enumerator degrades to one error-marked entry, never raises" do
      broken = Object.new
      def broken.all_raw
        raise "boom"
      end
      report = doctor(profile_source: Insika::StaticProfileSource.new, tool_store: broken).domain
      expect(report.count).to eq(1)
      entry = report.to_h["entries"].first
      expect(entry["kind"]).to eq("error")
      expect(entry["detail"]).to match(/read failed/)
    end

    it "to_s renders the human section with one line per entry" do
      profiles.put(Insika::AgentProfile.build(id: "x", model: "m", metadata: { "domain" => "retail" }))
      text = doctor(profile_source: profiles, tool_store: tool_store).domain.to_s
      expect(text).to include("domain: 3 artifact(s)")
      expect(text).to include("[persona] x: domain=retail (deployment)")

      empty = doctor(profile_source: Insika::StaticProfileSource.new, tool_store: tool_store).domain.to_s
      expect(empty).to include("domain: 0 artifacts")
    end
  end
end

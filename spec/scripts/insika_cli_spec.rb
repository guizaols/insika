# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "json"
require "fileutils"

# Integration proof of the `insika` CLI (— "config estrito +
# doctor --fix"). Shells out to the real binary so the exit codes and the
# store-backed --fix path are exercised end to end. HERMETIC: a clean, minimal env
# (no inherited HARNESS_*) + a throwaway SQLite file, never a shared deployment.
RSpec.describe "bin/insika" do
  let(:bin) { File.expand_path("../../bin/insika", __dir__) }

  # Run with a CONTROLLED env (unset_others so the runner's INSIKA_*/HARNESS_*/
  # ADMIN_TOKEN never leak in). -> [stdout, status].
  def run(*args, env: {})
    base = { "INSIKA_DB" => nil, "HARNESS_DB" => nil, "ADMIN_TOKEN" => nil, "DEEPSEEK_API_KEY" => nil,
             "DEEPSEEK_MODEL" => nil, "INSIKA_CONFIG_STRICT" => nil, "HARNESS_CONFIG_STRICT" => nil }
    out, status = Open3.capture2e(base.merge(env), "ruby", bin, *args, unsetenv_others: false)
    [out, status]
  end

  it "version prints the engine version" do
    out, status = run("version")
    expect(out).to include("insika #{Insika::VERSION}")
    expect(status).to be_success
  end

  it "help lists the commands" do
    out, status = run("help")
    expect(out).to match(/doctor.*diagnose/m)
    expect(out).to match(/env\b/)
    expect(status).to be_success
  end

  it "an unknown command exits 2 with usage" do
    out, status = run("frobnicate")
    expect(out).to match(/unknown command/)
    expect(status.exitstatus).to eq(2)
  end

  it "soak --help prints the soak usage and exits 0" do
    out, status = run("soak", "--help")
    expect(out).to match(/insika soak/)
    expect(out).to match(/--verify/)
    expect(status).to be_success
  end

  it "soak with no mode exits 2 with usage" do
    out, status = run("soak")
    expect(out).to match(/choose exactly one/)
    expect(status.exitstatus).to eq(2)
  end

  it "env lists the known keys with (unset) values" do
    out, status = run("env")
    expect(out).to match(/^INSIKA_DB\s+path\s+\(unset\)/)
    expect(out).to match(/^ADMIN_TOKEN\s+string\s+\(unset\)/)
    expect(status).to be_success
  end

  it "env masks a secret value" do
    out, _ = run("env", env: { "ADMIN_TOKEN" => "supersecret" })
    expect(out).to match(/ADMIN_TOKEN.*•+ \(set, 11 chars\)/)
    expect(out).not_to include("supersecret")
  end

  it "doctor on a fresh ephemeral deploy exits 0 (warnings only)" do
    out, status = run("doctor")
    expect(out).to include("ephemeral backend")
    expect(out).to match(/config OK/)
    expect(status).to be_success
  end

  it "doctor exits 1 on an unknown HARNESS_ key (error)" do
    out, status = run("doctor", env: { "HARNESS_BOGUS" => "1" })
    expect(out).to match(/HARNESS_BOGUS is not a known config key/)
    expect(status.exitstatus).to eq(1)
  end

  it "doctor --json emits a machine-readable report" do
    out, _ = run("doctor", "--json", env: { "HARNESS_BOGUS" => "1" })
    report = JSON.parse(out)
    expect(report["ok"]).to be(false)
    expect(report["findings"]).to be_an(Array)
    expect(report["findings"].map { |f| f["message"] }.join).to match(/HARNESS_BOGUS/)
  end

  it "doctor --domain prints the domain section (bare boot: zero artifacts, exit 0)" do
    out, status = run("doctor", "--domain")
    expect(out).to match(/domain: 0 artifacts/)
    expect(status).to be_success # informational — never a gate
  end

  it "doctor --json --domain merges the domain report into the envelope" do
    out, _ = run("doctor", "--json", "--domain")
    report = JSON.parse(out)
    expect(report["domain"]["count"]).to eq(0)
    expect(report["domain"]["entries"]).to eq([])
    expect(report["domain"]["gem_version"]).to eq(Insika::VERSION)
  end

  # the boot gate — a typo'd corpus language must fail `doctor`
  # (exit 1), not the first turn. The agent is seeded straight into the store.
  it "doctor exits 1 on a malformed guardrails.corpora declaration" do
    Dir.mktmpdir do |dir|
      db = File.join(dir, "cli.db")
      cs = Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
      profile = Insika::AgentProfile.build(id: "typo", model: "m",
                                           guardrails: { "corpora" => { "languages" => ["es"] } })
      cs.put("agents", "typo", profile.to_h)

      out, status = run("doctor", env: { "INSIKA_DB" => db })
      expect(out).to match(/malformed guardrails\.corpora/)
      expect(status.exitstatus).to eq(1)
    end
  end

  it "doctor --fix migrates settings + seeds default_model against a durable SQLite" do
    Dir.mktmpdir do |dir|
      db = File.join(dir, "cli.db")
      # seed a PRE-VERSIONING settings record with no default_model.
      cs = Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
      cs.put("settings", "general", { "streaming" => true })

      out, status = run("doctor", "--fix", env: { "INSIKA_DB" => db, "DEEPSEEK_MODEL" => "deepseek-chat" })
      expect(out).to match(/settings schema at v#{Insika::SettingsStore::SCHEMA_VERSION}/)
      expect(out).to match(/platform default model: deepseek-chat/)
      expect(status).to be_success

      # persisted?
      ss = Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db)))
      expect(ss.stored_schema_version).to eq(Insika::SettingsStore::SCHEMA_VERSION)
      expect(ss.get["default_model"]).to eq("deepseek-chat")
    end
  end

  describe "harvest" do
    VALID_CRITERION = <<~MD
      # criterion fixture

      ```yaml
      version: 1
      metric: primary
      window: 72h
      threshold: 0.05
      min_span: 28d
      ```
    MD

    NEGATIVE_RULES = <<~MD
      # negative list fixture

      ## Restrictions

      - `no-competitor-prices` — "concorrente" — never mention competitors or their prices
      - `no-competitor-store` — "outra loja" — never steer the customer to another store
      - `no-refund-promise` — /nao devolvemos/i — the refund policy is the human's answer, never a skill's
      - `no-delivery-promise` — "garantimos a entrega" — delivery promises are the human's call
    MD

    it "harvest:criterion check exits 0 on a valid frozen file and prints the rule" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "CRITERION.md")
        File.write(file, VALID_CRITERION)
        out, status = run("harvest:criterion", "check", "--file", file)
        expect(out).to match(/criterion ok: primary \/ 72h threshold 0.05 min_span 28d/)
        expect(status).to be_success
      end
    end

    it "harvest:criterion check without --file aborts" do
      out, status = run("harvest:criterion", "check")
      expect(out).to match(/--file is required/)
      expect(status.exitstatus).to eq(1)
    end

    it "harvest:criterion check exits non-zero on a broken file" do
      Dir.mktmpdir do |dir|
        bad = File.join(dir, "CRITERION.md")
        File.write(bad, "# no block\n")
        out, status = run("harvest:criterion", "check", "--file", bad)
        expect(status.exitstatus).to eq(1)
        expect(out).to match(/no ```yaml block/)
      end
    end

    it "harvest:negative import seeds the profile's negative_list from the rules file" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        rules = File.join(dir, "NEGATIVE.md")
        File.write(rules, NEGATIVE_RULES)
        cs = Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
        profiles = Insika::StoredProfileSource.new(config_store: cs)
        profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m",
                                                harvest: { "enabled" => true }))

        out, status = run("harvest:negative", "import", "--agent", "store-support",
                          "--file", rules, env: { "INSIKA_DB" => db })
        expect(out).to match(/imported 4 rule\(s\)/)
        expect(status).to be_success

        reloaded = Insika::StoredProfileSource.new(
          config_store: Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
        ).fetch("store-support")
        expect(reloaded.harvest["negative_list"]).to be_an(Array)
        expect(reloaded.harvest["negative_list"].map { |r| r["rule"] })
          .to include("no-competitor-prices")
      end
    end

    it "harvest:negative import on an unknown agent exits non-zero" do
      Dir.mktmpdir do |dir|
        rules = File.join(dir, "NEGATIVE.md")
        File.write(rules, NEGATIVE_RULES)
        out, status = run("harvest:negative", "import", "--agent", "nope", "--file", rules)
        expect(out).to match(/not configured/)
        expect(status.exitstatus).to eq(1)
      end
    end

    it "harvest:negative import without --file aborts" do
      out, status = run("harvest:negative", "import", "--agent", "store-support")
      expect(out).to match(/--file is required/)
      expect(status.exitstatus).to eq(1)
    end

    it "harvest without --agent aborts" do
      out, status = run("harvest")
      expect(out).to match(/--agent is required/)
      expect(status.exitstatus).to eq(1)
    end

    it "harvest on an unknown agent exits 2 with the name" do
      out, status = run("harvest", "--agent", "store-support")
      expect(out).to match(/not configured/)
      expect(status.exitstatus).to eq(2)
    end

    it "harvest on an agent without a harvest declaration reports skipped (disabled)" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        cs = Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
        profiles = Insika::StoredProfileSource.new(config_store: cs)
        profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m"))

        out, status = run("harvest", "--agent", "store-support", env: { "INSIKA_DB" => db })
        expect(out).to match(/skipped \(disabled\)/)
        expect(status).to be_success
      end
    end
  end

  describe "evals:simulate" do
    def persona_file(dir, overrides = {})
      path = File.join(dir, "persona.yml")
      File.write(path, YAML.dump({
        "id" => "loja-sim", "agent" => "loja",
        "persona" => { "goal" => "find a gift under R$100", "knows" => { "budget" => "100" },
                       "opens_with" => "oi, queria um presente", "max_turns" => 4 },
        "expect" => {}
      }.merge(overrides)))
      path
    end

    it "refuses to run without --staging or --eval-profile (a simulated run must not write for real)" do
      Dir.mktmpdir do |dir|
        out, status = run("evals:simulate", "--persona", persona_file(dir), "--target", "loja")
        expect(out).to match(/must not write for real/)
        expect(out).to match(/--staging/)
        expect(status.exitstatus).to eq(1)
      end
    end

    it "aborts without --persona or --target" do
      out, _ = run("evals:simulate")
      expect(out).to match(/--persona is required/)
      out, _ = run("evals:simulate", "--persona", "x.yml")
      expect(out).to match(/--target is required/)
    end

    it "refuses a scripted case (no persona) — only simulated cases can be driven here" do
      Dir.mktmpdir do |dir|
        bad = File.join(dir, "scripted.yml")
        File.write(bad, "id: x\nagent: a\nturns:\n  - user: oi\nexpect: {}\n")
        out, status = run("evals:simulate", "--persona", bad, "--target", "loja", "--staging")
        expect(out).to match(/needs a `persona:`/)
        expect(status.exitstatus).to eq(2)
      end
    end

    # Safety: --eval-profile must DERIVE the target's side-effect tools
    # (from the store's registry here) and refuse a swap that does not cover them —
    # a bare `--eval-profile` on a write-capable agent is the trust-me flag the
    # docs promise is not what happens.
    def seed_store_with_write_tool(db)
      cs = Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
      profiles = Insika::StoredProfileSource.new(config_store: cs)
      profiles.put(Insika::AgentProfile.build(id: "loja", model: "m", tools_allow: %w[search_products create_order]))
      tool_store = Insika::ToolStore.new(config_store: cs)
      tool_store.write(Insika::ToolDefinition.build(
                         name: "search_products", description: "d",
                         request: { method: "GET", url: "https://example.invalid/search" },
                         response: { extract: "status" }, parameters: { type: "object", properties: {} }
                       ).to_h)
      tool_store.write(Insika::ToolDefinition.build(
                         name: "create_order", description: "d",
                         request: { method: "POST", url: "https://example.invalid/order" },
                         response: { extract: "status" }, parameters: { type: "object", properties: {} }
                       ).to_h)
    end

    it "refuses --eval-profile when the derived side-effect tools are not declared in --eval-tools" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        seed_store_with_write_tool(db)
        out, status = run("evals:simulate", "--persona", persona_file(dir), "--target", "loja",
                          "--eval-profile", env: { "INSIKA_DB" => db })
        expect(out).to match(/derived side-effect tool\(s\) \(create_order\)/)
        expect(out).to match(/--eval-tools/)
        expect(status.exitstatus).to eq(1)
      end
    end

    it "accepts --eval-profile when --eval-tools covers the derived side-effect tools" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        seed_store_with_write_tool(db)
        # The safety gate passes (the swap covers the derived list); the run then
        # aborts only because no persona model is configured — NOT on safety.
        out, status = run("evals:simulate", "--persona", persona_file(dir), "--target", "loja",
                          "--eval-profile", "--eval-tools", "create_order",
                          env: { "INSIKA_DB" => db })
        expect(out).not_to match(/side-effect/)
        expect(out).to match(/no persona model/)
        expect(status.exitstatus).to eq(1)
      end
    end

    it "requires the explicit --eval-tools list for an A2A target (no reachable registry)" do
      Dir.mktmpdir do |dir|
        out, status = run("evals:simulate", "--persona", persona_file(dir),
                          "--target", "https://a2a.example.com", "--eval-profile")
        expect(out).to match(/declare the swap list explicitly/)
        expect(status.exitstatus).to eq(1)
      end
    end
  end

  describe "mcp" do
    it "list on a fresh deploy says there is nothing configured" do
      out, status = run("mcp", "list")
      expect(out).to match(/no MCP instances configured/)
      expect(status).to be_success
    end

    it "add then list shows the saved instance, never the header value" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        out, status = run("mcp", "add", "--name", "tavily", "--transport", "http",
                          "--url", "https://mcp.tavily.com/mcp",
                          "--header", "Authorization: Bearer supersecret",
                          env: { "INSIKA_DB" => db })
        expect(out).to match(/'tavily' saved \(http, enabled\)/)
        expect(status).to be_success

        out, status = run("mcp", "list", env: { "INSIKA_DB" => db })
        expect(out).to match(/tavily\s+http\s+enabled\s+https:\/\/mcp\.tavily\.com\/mcp\s+0 tool\(s\)/)
        expect(out).not_to include("supersecret")
        expect(status).to be_success
      end
    end

    it "add without --transport defaults to stdio when --command is given, else http" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        run("mcp", "add", "--name", "fs", "--command", "npx", env: { "INSIKA_DB" => db })
        run("mcp", "add", "--name", "remote", "--url", "https://example.com/mcp", env: { "INSIKA_DB" => db })
        out, = run("mcp", "list", env: { "INSIKA_DB" => db })
        expect(out).to match(/fs\s+stdio/)
        expect(out).to match(/remote\s+http/)
      end
    end

    it "add without --name exits 2" do
      out, status = run("mcp", "add", "--url", "https://example.com/mcp")
      expect(out).to match(/--name is required/)
      expect(status.exitstatus).to eq(2)
    end

    it "remove deletes an existing instance and is idempotent on a missing one" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        run("mcp", "add", "--name", "tavily", "--url", "https://mcp.tavily.com/mcp", env: { "INSIKA_DB" => db })

        out, status = run("mcp", "remove", "tavily", env: { "INSIKA_DB" => db })
        expect(out).to match(/'tavily' removed/)
        expect(status).to be_success

        out, status = run("mcp", "remove", "tavily", env: { "INSIKA_DB" => db })
        expect(out).to match(/'tavily' did not exist/)
        expect(status).to be_success
      end
    end

    it "import upserts every entry of a mcpServers JSON document" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        file = File.join(dir, "mcpServers.json")
        File.write(file, JSON.generate({
          "mcpServers" => {
            "filesystem" => { "command" => "npx", "args" => ["-y", "server-filesystem"] },
            "tavily" => { "url" => "https://mcp.tavily.com/mcp", "headers" => { "Authorization" => "Bearer x" } }
          }
        }))

        out, status = run("mcp", "import", file, env: { "INSIKA_DB" => db })
        expect(out).to match(/imported 2 MCP instance\(s\)/)
        expect(out).to match(/filesystem \(stdio\)/)
        expect(out).to match(/tavily \(http\)/)
        expect(status).to be_success
      end
    end

    it "import on a missing file exits 2" do
      out, status = run("mcp", "import", "/no/such/file.json")
      expect(out).to match(/no such file/)
      expect(status.exitstatus).to eq(2)
    end

    it "test/refresh on an unknown instance exits 1 with a clean message" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        out, status = run("mcp", "test", "nope", env: { "INSIKA_DB" => db })
        expect(out).to match(/'nope'.*not found/)
        expect(status.exitstatus).to eq(1)
      end
    end

    it "test on a stdio instance without INSIKA_MCP_STDIO reports the gate, not a crash" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        run("mcp", "add", "--name", "fs", "--command", "npx", env: { "INSIKA_DB" => db })
        out, status = run("mcp", "test", "fs", env: { "INSIKA_DB" => db })
        expect(out).to match(/stdio \(arbitrary command execution by config\)/)
        expect(status.exitstatus).to eq(1)
      end
    end

    it "an unknown mcp subcommand exits 2" do
      out, status = run("mcp", "bogus")
      expect(out).to match(/unknown subcommand/)
      expect(status.exitstatus).to eq(2)
    end
  end

  describe "new" do
    it "--list shows the wave-1 roster with trail + description" do
      out, status = run("new", "--list")
      expect(out).to match(/travel-planner\s+Starter/)
      expect(out).to match(/repo-explorer\s+MCP/)
      expect(status).to be_success
    end

    it "copies the template verbatim into the given dir and prints the run line" do
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "my-planner")
        out, status = run("new", "travel-planner", dest)
        expect(status).to be_success
        expect(out).to include("Created #{dest}/ (Travel Planner)")
        expect(out).to match(/DEEPSEEK_API_KEY=sk-\.\.\. ruby #{Regexp.escape(dest)}\/agent\.rb/)
        expect(File.read(File.join(dest, "agent.rb"))).to include('Insika.agent("travel-planner")')
        expect(File.file?(File.join(dest, "README.md"))).to be(true)
      end
    end

    it "defaults the destination to ./<template> when no dir is given" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          out, status = run("new", "travel-planner")
          expect(status).to be_success
          expect(out).to include("Created ./travel-planner/")
          expect(File.file?(File.join(dir, "travel-planner", "agent.rb"))).to be(true)
        end
      end
    end

    it "a stdio/MCP template's run line states its required env up front" do
      Dir.mktmpdir do |dir|
        out, = run("new", "browser-agent", File.join(dir, "b"))
        expect(out).to match(/INSIKA_MCP_STDIO=1 DEEPSEEK_API_KEY=sk-\.\.\./)
        expect(out).to include("Requires: Node.js and npm")
      end
    end

    it "refuses to overwrite an existing destination" do
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "taken")
        FileUtils.mkdir_p(dest)
        out, status = run("new", "travel-planner", dest)
        expect(out).to match(/already exists/)
        expect(status.exitstatus).to eq(2)
      end
    end

    it "an unknown template name exits 2, not a crash" do
      out, status = run("new", "bogus-template")
      expect(out).to match(/template 'bogus-template' not found/)
      expect(status.exitstatus).to eq(2)
    end
  end
end

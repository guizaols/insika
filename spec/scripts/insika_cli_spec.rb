# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "json"

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
end

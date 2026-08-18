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

  describe "harvest (RFC-0035 C15)" do
    it "harvest:criterion check exits 0 on the committed file and prints the frozen rule" do
      out, status = run("harvest:criterion", "check")
      expect(out).to match(/criterion ok: primary \/ 72h threshold 0.05 min_span 28d/)
      expect(status).to be_success
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

    it "harvest:negative import seeds the profile's negative_list from the versioned file" do
      Dir.mktmpdir do |dir|
        db = File.join(dir, "cli.db")
        cs = Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
        profiles = Insika::StoredProfileSource.new(config_store: cs)
        profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m",
                                                harvest: { "enabled" => true }))

        out, status = run("harvest:negative", "import", "--agent", "store-support",
                          env: { "INSIKA_DB" => db })
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
      out, status = run("harvest:negative", "import", "--agent", "nope")
      expect(out).to match(/not configured/)
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

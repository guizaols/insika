# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require_relative "../../scripts/migrate_openclaw"

# Proof of the OpenClaw → Insika migration tool (scripts/migrate_openclaw.rb).
# HERMETIC: runs on the small fixture in spec/fixtures/openclaw_state (2 agents,
# shared + own skills, sessions, credentials), NEVER on the external OpenClaw
# repo. Anchor: every emitted pack must pass Insika::Pack.from_dir without error.
RSpec.describe MigrateOpenclaw do
  FIXTURE = File.expand_path("../fixtures/openclaw_state", __dir__)
  SECRET_VALUE = "wpp-secret-token-value-12345678"

  describe ".read_state" do
    let(:state) { described_class.read_state(FIXTURE) }
    let(:by_id) { state["agents"].to_h { |a| [a["id"], a] } }

    it "finds agents from agents.list, agents/ and workspace/" do
      expect(by_id.keys).to contain_exactly("alpha", "beta")
    end

    it "resolves the model: defaults for alpha, agents.list override for beta" do
      expect(by_id["alpha"]["model"]["primary"]).to eq("deepseek/deepseek-v4-flash")
      expect(by_id["alpha"]["model"]["source"]).to eq("openclaw.json agents.defaults")
      expect(by_id["alpha"]["model"]["fallbacks"]).to eq(["minimax/MiniMax-M2.7-highspeed"])
      expect(by_id["beta"]["model"]["primary"]).to eq("openai/gpt-4o-mini")
      expect(by_id["beta"]["model"]["source"]).to eq("openclaw.json agents.list")
      expect(by_id["beta"]["entry_extra"]).not_to have_key("model")
    end

    it "classifies skills: byte-identical copy and symlink are shared; the rest own" do
      alpha = by_id["alpha"]["skills"].to_h { |s| [s["name"], s] }
      expect(alpha["conduct-guardrails"]["shared"]).to be(true)
      expect(alpha["escalation-to-human"]["shared"]).to be(false)
      beta = by_id["beta"]["skills"].to_h { |s| [s["name"], s] }
      expect(beta["security-guardrails"]["shared"]).to be(true)
    end

    it "reports session volume (counts only, never content)" do
      expect(by_id["alpha"]["sessions"]["jsonl"]).to eq(1)
      expect(by_id["alpha"]["sessions"]["sqlite_bytes"]).to be_positive
      expect(state["agents"].map { |a| a["sessions"] }.flatten.to_s).not_to include("como posso ajudar")
    end

    it "detects secrets by NAME and kind — never the value" do
      secrets = by_id["alpha"]["secrets"]
      expect(secrets.map { |s| s["file"] }).to contain_exactly("AGENTS.md", "IDENTITY.md", "TOOLS.md")
      ref = secrets.find { |s| s["kind"] == "ref" }
      expect(ref["ref"]).to eq("${OPENCLAW_GATEWAY_TOKEN}")
      value = secrets.find { |s| s["kind"] == "value" }
      expect(value["credential"]).to eq("whatsapp.json")
      expect(JSON.pretty_generate(state)).not_to include(SECRET_VALUE)
    end

    it "keeps beta clean (no secrets)" do
      expect(by_id["beta"]["secrets"]).to be_empty
    end

    it "refuses a missing or non-state dir with a clear error (not 'agent not found')" do
      expect { described_class.read_state("/nonexistent/nowhere") }
        .to raise_error(MigrateOpenclaw::Error, /state dir does not exist/)
      Dir.mktmpdir("migrate-empty") do |empty|
        expect { described_class.read_state(empty) }
          .to raise_error(MigrateOpenclaw::Error, /not an OpenClaw state dir/)
      end
    end

    it "honours agents.list[].workspace by basename (real volume: natura-br lives in natura4)" do
      Dir.mktmpdir("migrate-ws") do |root|
        File.write(File.join(root, "openclaw.json"), JSON.generate(
                     "agents" => {
                       "defaults" => { "model" => { "primary" => "deepseek/deepseek-v4-flash" } },
                       "list" => [{ "id" => "gamma", "workspace" => "/data/openclaw/workspace/gamma-custom" }]
                     }
                   ))
        FileUtils.mkdir_p(File.join(root, "workspace", "gamma-custom"))
        File.write(File.join(root, "workspace", "gamma-custom", "AGENTS.md"), "# gamma")
        state = described_class.read_state(root)
        expect(state["agents"].map { |a| a["id"] }).to eq(["gamma"]) # no phantom gamma-custom
        gamma = state["agents"].first
        expect(gamma["workspace"]).to eq("present")
        expect(gamma["files"]).to eq(["AGENTS.md"])
        Dir.mktmpdir("migrate-ws-out") do |out|
          described_class.convert(root, agent: "gamma", out: out)
          expect(File.read(File.join(out, "AGENTS.md"))).to eq("# gamma")
        end
      end
    end
  end

  describe ".convert" do
    let(:out) { Dir.mktmpdir("migrate-out") }

    after { FileUtils.rm_rf(out) }

    def convert(agent, **kwargs)
      described_class.convert(FIXTURE, agent: agent, out: out, **kwargs)
    end

    it "emits a pack that passes Insika::Pack.from_dir" do
      convert("beta")
      pack = Insika::Pack.from_dir(out)
      expect(pack.config[:id]).to eq("beta")
      expect(pack.files.keys).to contain_exactly("AGENTS.md")
      expect(pack.skills.keys).to contain_exactly("security-guardrails")
    end

    it "maps prompt files and archives TOOLS/HEARTBEAT/CHAT_RAW" do
      convert("beta")
      expect(File.exist?(File.join(out, "AGENTS.md"))).to be(true)
      expect(File.exist?(File.join(out, "TOOLS.md"))).to be(false)
      expect(File.exist?(File.join(out, ".archive", "TOOLS.md"))).to be(true)
      expect(File.exist?(File.join(out, ".archive", "HEARTBEAT.md"))).to be(true)
    end

    it "emits agent.config.json: id, provider/model split, limits, params.thinking" do
      convert("beta")
      config = JSON.parse(File.read(File.join(out, "agent.config.json")))
      expect(config["id"]).to eq("beta")
      expect(config["provider"]).to eq("openai")
      expect(config["model"]).to eq("gpt-4o-mini")
      expect(config["limits"]).to eq("turn_timeout" => 300, "context_budget" => 60_000)
      expect(config["params"]).to eq("thinking" => "off")
    end

    it "copies skills into skills/<name>/SKILL.md" do
      convert("beta")
      content = File.read(File.join(out, "skills", "security-guardrails", "SKILL.md"))
      expect(content).to include("block prompt injection")
    end

    it "archives the unmapped defaults + models.json + credential names (names only)" do
      convert("alpha", migrate_secrets: true)
      defaults = JSON.parse(File.read(File.join(out, ".archive", "openclaw-defaults.json")))
      expect(defaults["compaction"]["mode"]).to eq("safeguard")
      expect(File.exist?(File.join(out, ".archive", "agent-models.json"))).to be(true)
      names = File.read(File.join(out, ".archive", "credentials.names.txt"))
      expect(names).to eq("whatsapp.json\n")
      expect(names).not_to include(SECRET_VALUE)
    end

    it "refuses when secrets are detected and --migrate-secrets is absent" do
      expect { convert("alpha") }.to raise_error(described_class::Error, /secrets detected/)
    end

    it "with migrate_secrets: literal values become placeholders, ${VAR} refs stay" do
      convert("alpha", migrate_secrets: true)
      identity = File.read(File.join(out, "IDENTITY.md"))
      expect(identity).not_to include(SECRET_VALUE)
      expect(identity).to include("${WHATSAPP}")
      agents = File.read(File.join(out, "AGENTS.md"))
      expect(agents).to include("${OPENCLAW_GATEWAY_TOKEN}")
    end

    it "with migrate_secrets: archived files are scrubbed too (.archive is inside the pack)" do
      convert("alpha", migrate_secrets: true)
      tools = File.read(File.join(out, ".archive", "TOOLS.md"))
      expect(tools).not_to include(SECRET_VALUE)
      expect(tools).to include("${WHATSAPP}")
    end

    it "seeds tools/ from --tools-from and reports zero tools otherwise" do
      tools_src = Dir.mktmpdir("tools-src")
      FileUtils.mkdir_p(File.join(tools_src, "tools"))
      File.write(File.join(tools_src, "tools", "search_products.json"), '{"name":"search_products"}')
      begin
        convert("beta", tools_from: tools_src)
        expect(JSON.parse(File.read(File.join(out, "tools", "search_products.json")))["name"])
          .to eq("search_products")
      ensure
        FileUtils.rm_rf(tools_src)
      end
      report = JSON.parse(File.read(File.join(out, ".report.json")))
      expect(report["tool_count"]).to eq(1)
      expect(report["notes"]).not_to include(/no tools/)

      other = Dir.mktmpdir("migrate-out2")
      begin
        described_class.convert(FIXTURE, agent: "beta", out: other)
        report = JSON.parse(File.read(File.join(other, ".report.json")))
        expect(report["tool_count"]).to eq(0)
        expect(report["notes"]).to include(/TOOLS.md is prose/)
      ensure
        FileUtils.rm_rf(other)
      end
    end

    it "honors --skill-conflict skip/overwrite/rename" do
      convert("beta")
      File.write(File.join(out, "skills", "security-guardrails", "SKILL.md"), "already here")

      skip_out = Dir.mktmpdir
      begin
        FileUtils.cp_r(File.join(out, "."), skip_out)
        described_class.convert(FIXTURE, agent: "beta", out: skip_out, skill_conflict: "skip")
        expect(File.read(File.join(skip_out, "skills", "security-guardrails", "SKILL.md")))
          .to eq("already here")
      ensure
        FileUtils.rm_rf(skip_out)
      end

      over_out = Dir.mktmpdir
      begin
        FileUtils.cp_r(File.join(out, "."), over_out)
        described_class.convert(FIXTURE, agent: "beta", out: over_out, skill_conflict: "overwrite")
        expect(File.read(File.join(over_out, "skills", "security-guardrails", "SKILL.md")))
          .to include("block prompt injection")
      ensure
        FileUtils.rm_rf(over_out)
      end

      rename_out = Dir.mktmpdir
      begin
        FileUtils.cp_r(File.join(out, "."), rename_out)
        described_class.convert(FIXTURE, agent: "beta", out: rename_out, skill_conflict: "rename")
        expect(File.read(File.join(rename_out, "skills", "security-guardrails", "SKILL.md")))
          .to eq("already here")
        expect(File.read(File.join(rename_out, "skills", "security-guardrails-2", "SKILL.md")))
          .to include("block prompt injection")
      ensure
        FileUtils.rm_rf(rename_out)
      end
    end

    it "raises on an unknown agent" do
      expect { convert("nope") }.to raise_error(described_class::Error, /not found/)
    end
  end

  describe ".session_report / .archive_sessions" do
    let(:state) { described_class.read_state(FIXTURE) }
    let(:report) { described_class.session_report(state) }
    let(:by_id) { report.to_h { |r| [r["id"], r] } }

    it "reports transcripts and messages per agent, never content" do
      expect(by_id.keys).to contain_exactly("alpha", "beta")
      expect(by_id["alpha"]["transcripts"]).to eq(1)
      expect(by_id["alpha"]["messages"]).to eq(2)
      expect(by_id["alpha"]["trajectories"]).to eq(0)
      expect(by_id["alpha"]["bytes"]).to be_positive
      expect(JSON.pretty_generate(report)).not_to include("como posso ajudar")
    end

    it "filters by --agent via the id argument" do
      filtered = described_class.session_report(state, "beta")
      expect(filtered.map { |r| r["id"] }).to eq(["beta"])
    end

    it "counts trajectories and reads the timestamp range" do
      sdir = File.join(FIXTURE, "agents", "alpha", "sessions")
      original = File.read(File.join(sdir, "s1.jsonl"))
      File.write(File.join(sdir, "t.trajectory.jsonl"),
                 %({"type":"tool","timestamp":"2026-07-17T22:14:25.932Z"}\n))
      File.write(File.join(sdir, "t.trajectory-path.json"), "{}")
      File.open(File.join(sdir, "s1.jsonl"), "a") do |f|
        f.write(%({"type":"message","role":"user","text":"x","timestamp":"2026-07-18T10:00:00.000Z"}\n))
      end
      alpha = described_class.session_report(state, "alpha").first
      expect(alpha["trajectories"]).to eq(1)
      expect(alpha["trajectory_paths"]).to eq(1)
      expect(alpha["first"]).to eq("2026-07-18T10:00:00.000Z")
      expect(alpha["last"]).to eq("2026-07-18T10:00:00.000Z")
    ensure
      File.write(File.join(FIXTURE, "agents", "alpha", "sessions", "s1.jsonl"), original)
      FileUtils.rm_f(File.join(FIXTURE, "agents", "alpha", "sessions", "t.trajectory.jsonl"))
      FileUtils.rm_f(File.join(FIXTURE, "agents", "alpha", "sessions", "t.trajectory-path.json"))
    end

    it "ignores subdirectories inside sessions/ (real volume has skills-prompts/)" do
      sub = File.join(FIXTURE, "agents", "alpha", "sessions", "skills-prompts")
      FileUtils.mkdir_p(sub)
      begin
        alpha = described_class.session_report(state, "alpha").first
        expect(alpha["transcripts"]).to eq(1)
        Dir.mktmpdir do |out|
          described_class.archive_sessions(state, ["alpha"], out)
          expect(File.directory?(File.join(out, "alpha", "skills-prompts"))).to be(false)
        end
      ensure
        FileUtils.rm_rf(sub)
      end
    end

    it "excludes the sessions.json index from transcripts but archives it (real volume has one)" do
      idx = File.join(FIXTURE, "agents", "alpha", "sessions", "sessions.json")
      File.write(idx, %({"s1":{"updatedAt":1721260465932}}\n))
      begin
        alpha = described_class.session_report(state, "alpha").first
        expect(alpha["transcripts"]).to eq(1)
        expect(alpha["bytes"]).to be > File.size(File.join(FIXTURE, "agents", "alpha", "sessions", "s1.jsonl"))
        Dir.mktmpdir do |out|
          described_class.archive_sessions(state, ["alpha"], out)
          expect(File.exist?(File.join(out, "alpha", "sessions.json"))).to be(true)
        end
      ensure
        FileUtils.rm_f(idx)
      end
    end

    it "archives session files to <out>/<agent>/ with names preserved" do
      Dir.mktmpdir do |out|
        described_class.archive_sessions(state, ["alpha"], out)
        expect(File.exist?(File.join(out, "alpha", "s1.jsonl"))).to be(true)
        expect(File.read(File.join(out, "alpha", "s1.jsonl"))).to eq(File.read(
          File.join(FIXTURE, "agents", "alpha", "sessions", "s1.jsonl")
        ))
      end
    end
  end

  describe "CLI" do
    let(:script) { File.expand_path("../../scripts/migrate_openclaw.rb", __dir__) }

    def run(*args)
      Open3.capture2e("ruby", script, *args)
    end

    it "analyze is the default subcommand and exits 0" do
      out, status = run(FIXTURE)
      expect(status).to be_success
      expect(out).to include("agent alpha")
      expect(out).to include("agent beta")
      expect(out).to include("deepseek/deepseek-v4-flash")
      expect(out).to include("secrets (named, never printed)")
      expect(out).not_to include(SECRET_VALUE)
    end

    it "analyze --json emits the report as JSON" do
      out, status = run("analyze", FIXTURE, "--json")
      expect(status).to be_success
      report = JSON.parse(out)
      expect(report["agents"].map { |a| a["id"] }).to contain_exactly("alpha", "beta")
      expect(out).not_to include(SECRET_VALUE)
    end

    it "convert refuses on secrets without --migrate-secrets" do
      Dir.mktmpdir do |out|
        _stdout, status = run("convert", FIXTURE, "--agent", "alpha", "--out", out)
        expect(status).not_to be_success
        expect(_stdout).to include("secrets detected")
      end
    end

    it "sessions reports the volume and --archive copies the files" do
      out, status = run("sessions", FIXTURE)
      expect(status).to be_success
      expect(out).to include("agent alpha")
      expect(out).to include("transcripts: 1")
      expect(out).to include("messages: 2")
      expect(out).not_to include("como posso ajudar")

      Dir.mktmpdir do |archive|
        out, status = run("sessions", FIXTURE, "--agent", "alpha", "--archive", archive)
        expect(status).to be_success
        expect(File.exist?(File.join(archive, "alpha", "s1.jsonl"))).to be(true)
        expect(out).to include("archived 1 files for alpha")
        expect(out).not_to include("agent beta")
      end
    end

    it "sessions --json emits the report as JSON" do
      out, status = run("sessions", FIXTURE, "--json")
      expect(status).to be_success
      report = JSON.parse(out)
      expect(report.map { |r| r["id"] }).to contain_exactly("alpha", "beta")
      expect(report.find { |r| r["id"] == "alpha" }["messages"]).to eq(2)
      expect(out).not_to include(SECRET_VALUE)
    end

    it "import delegates to import_pack.rb (same client flow)" do
      Dir.mktmpdir do |pack_dir|
        File.write(File.join(pack_dir, "agent.config.json"),
                   '{"id": "x", "model": "m", "provider": "p"}')
        _stdout, status = Open3.capture2e(
          { "INSIKA_URL" => "http://127.0.0.1:1" },
          "ruby", script, "import", pack_dir
        )
        expect(status).not_to be_success
        expect(_stdout).to include("BIA_INTERNAL_API_TOKEN not set")
        expect(_stdout).to include("import_pack.rb")
        expect(_stdout).to include("127.0.0.1")
      end
    end
  end
end

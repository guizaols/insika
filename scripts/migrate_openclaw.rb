# frozen_string_literal: true

# Migrate an OpenClaw state directory into Insika packs. GENERIC: input is any
# OpenClaw state dir (the layout below); the local dev repo and the Railway
# volume are just two ways to obtain one. The engine and the API are untouched
# — the pack is the contract (see docs/RUNNING-LOCAL.md#provisioning-an-agent).
#
# State layout (validated against the local OpenClaw repo):
#   openclaw.json                      # providers, agents.defaults, agents.list
#   agents/<id>/agent/models.json      # per-agent provider catalog / model override
#   agents/<id>/agent/openclaw-agent.sqlite
#   agents/<id>/sessions/*.jsonl
#   workspace/<id>/AGENTS.md IDENTITY.md SOUL.md USER.md MEMORY.md … TOOLS.md HEARTBEAT.md
#   workspace/<id>/skills/<name>/SKILL.md
#   skills-shared/<name>/              # shared skills (copied or symlinked into agents)
#   credentials/                       # platform allowlists/tokens
#
# Subcommands:
#   analyze <state-dir> [--json]
#       Read-only migration report: per agent and global — prompt files, skills
#       (own vs shared), resolved model, what maps to Insika and what has no
#       equivalent (archived, listed by name), session volume (counts only),
#       and secrets (DETECTED, NAMED, never printed). The default subcommand.
#
#   convert <state-dir> --agent <id> --out <dir>
#           [--tools-from <pack-dir>] [--skill-conflict skip|overwrite|rename]
#           [--migrate-secrets]
#       Emit an Insika pack (<dir>: agent.config.json + *.md + skills/ + tools/).
#       TOOLS.md is prose and cannot be derived into data tools — seed tools/
#       from --tools-from (a pack that already has them) or the agent ships
#       without tools, with a loud warning. HEARTBEAT.md / CHAT_RAW.md / the
#       unmapped defaults are ARCHIVED to <dir>/.archive/, never dropped.
#       Secrets: refuses when a file to migrate contains a ${VAR} ref or a
#       credentials/ value, unless --migrate-secrets (values then become
#       ${NAME} placeholders — the VALUE never lands in the pack).
#
#   import <pack-dir>
#       Delegates to scripts/import_pack.rb (Insika::Pack.from_dir →
#       POST /v1/agents). Same env as import_pack.rb (INSIKA_URL,
#       OPENCLAW_GATEWAY_TOKEN, BIA_INTERNAL_API_TOKEN).
#
# Railway volume (documented recipe; the volume is just a source of state dirs):
#   railway link   # the OpenClaw gateway project/service
#   railway ssh "tar czf - -C <volume-mount> ." > openclaw-volume.tgz
#   tar xzf openclaw-volume.tgz -C ./openclaw-state
#   ruby scripts/migrate_openclaw.rb analyze ./openclaw-state
# If binary streaming over railway ssh is flaky: tar | base64, decode locally.
# Never list_variables unfiltered (known leak gotcha).

require "json"
require "fileutils"
require "optparse"
require "rbconfig"

module MigrateOpenclaw
  class Error < StandardError; end

  # Workspace prompt files with no Insika equivalent: TOOLS.md describes the
  # tools in prose (the real tools live in the plugin, not here), HEARTBEAT.md
  # holds proactive cron tasks, CHAT_RAW.md is a log stub. ARCHIVED, not dropped.
  ARCHIVED_FILES = %w[TOOLS.md HEARTBEAT.md CHAT_RAW.md].freeze

  # The defaults keys that map to something on the Insika profile. Everything
  # else under agents.defaults is archived by name.
  MAPPED_DEFAULT_KEYS = %w[model timeoutSeconds].freeze

  # context_budget: OpenClaw bounds the prompt by chars (bootstrapMaxChars),
  # which has no token equivalent. Insika's default (8000) is smaller than a
  # store identity (~27k-48k), so a pack without a raised budget produces empty
  # turns. Same value the hand-built store packs use.
  CONTEXT_BUDGET = 60_000

  VAR_REF = /\$\{[A-Z][A-Z0-9_]*\}/
  MIN_CRED_VALUE_LENGTH = 8

  module_function

  # ---------- state reading ----------

  def read_json(path)
    JSON.parse(File.read(path, encoding: "UTF-8"))
  rescue Errno::ENOENT
    nil
  end

  def credential_names(root)
    dir = File.join(root, "credentials")
    return [] unless Dir.exist?(dir)

    Dir.children(dir).sort
  end

  # Values that appear inside credentials/*.json, big enough to not false-match
  # prose. Used ONLY for detection/scrubbing — never printed.
  def credential_values(root, names)
    names.filter_map do |name|
      raw = read_json(File.join(root, "credentials", name))
      next unless raw.is_a?(Hash)

      raw.values.filter_map { |v| v.is_a?(String) && v.length >= MIN_CRED_VALUE_LENGTH ? v : nil }
    end.flatten.uniq
  end

  def skill_md_files(ws_dir)
    skills_dir = File.join(ws_dir, "skills")
    return [] unless Dir.exist?(skills_dir)

    # Dir.glob does not descend into a SYMLINKED skill dir (the volume layout
    # symlinks shared skills), so walk the children and resolve.
    Dir.children(skills_dir).sort.filter_map do |name|
      dir = File.join(skills_dir, name)
      next unless File.directory?(dir)

      md = File.join(dir, "SKILL.md")
      md if File.exist?(md)
    end
  end

  # Shared = symlinked into skills-shared, or byte-identical to it (the local
  # repo stores copies, the volume stores symlinks — both happen in the wild).
  def shared_skill?(skill_path, name, shared_dir)
    return true if File.symlink?(File.dirname(skill_path))

    shared = File.join(shared_dir, name, "SKILL.md")
    File.exist?(shared) && File.binread(skill_path) == File.binread(shared)
  end

  def split_model_ref(ref)
    return [nil, nil] if ref.to_s.empty?

    ref.include?("/") ? ref.split("/", 2) : [nil, ref]
  end

  def detect_secrets(root, agent, cred_names)
    ws = File.join(root, "workspace", agent["id"])
    values = credential_values(root, cred_names)
    found = []
    agent["files"].each { |f| scan_secrets(File.join(ws, f), found, values, cred_names, root) }
    agent["skills"].each do |s|
      scan_secrets(File.join(ws, "skills", s["name"], "SKILL.md"), found, values, cred_names, root)
    end
    found
  end

  def scan_secrets(path, found, values, cred_names, root)
    return unless File.exist?(path)

    text = File.read(path, encoding: "UTF-8")
    text.scan(VAR_REF).uniq.each do |ref|
      found << { "file" => File.basename(path), "kind" => "ref", "ref" => ref }
    end
    values.each do |value|
      next unless text.include?(value)

      found << { "file" => File.basename(path), "kind" => "value",
                 "credential" => owner_of(value, cred_names, root) }
    end
  end

  def owner_of(value, cred_names, root)
    cred_names.find do |name|
      raw = read_json(File.join(root, "credentials", name))
      raw.is_a?(Hash) && raw.value?(value)
    end || "(unknown credential)"
  end

  def resolve_model(defaults, models)
    override = models["primary"] || models["model"]
    if override
      { "primary" => override, "source" => "agents/<id>/agent/models.json", "fallbacks" => [] }
    else
      dmodel = (defaults["model"] || {})
      { "primary" => dmodel["primary"], "source" => "openclaw.json agents.defaults",
        "fallbacks" => dmodel["fallbacks"] || [] }
    end
  end

  def classify_files(files)
    [files.reject { |f| ARCHIVED_FILES.include?(f) },
     files.select { |f| ARCHIVED_FILES.include?(f) }]
  end

  def read_state(dir)
    root = File.expand_path(dir)
    config = read_json(File.join(root, "openclaw.json")) || {}
    defaults = (config["agents"] || {})["defaults"] || {}
    list = (config["agents"] || {})["list"] || []

    ids = list.map { |e| e["id"] }.compact
    ids += Dir.children(File.join(root, "agents")).sort if Dir.exist?(File.join(root, "agents"))
    ids += Dir.children(File.join(root, "workspace")).sort if Dir.exist?(File.join(root, "workspace"))
    ids = ids.uniq.sort

    shared_dir = File.join(root, "skills-shared")
    creds = credential_names(root)

    agents = ids.map do |id|
      ws = File.join(root, "workspace", id)
      agent_dir = File.join(root, "agents", id, "agent")
      models = read_json(File.join(agent_dir, "models.json")) || {}
      entry = list.find { |e| e["id"] == id } || {}

      files = Dir.exist?(ws) ? Dir.glob(File.join(ws, "*.md")).sort.map { |f| File.basename(f) } : []
      skills = skill_md_files(ws).map do |f|
        name = File.basename(File.dirname(f))
        { "name" => name, "shared" => shared_skill?(f, name, shared_dir) }
      end

      session_dir = File.join(root, "agents", id, "sessions")
      jsonl = Dir.exist?(session_dir) ? Dir.glob(File.join(session_dir, "*.jsonl")).size : 0
      sqlite_bytes = File.size?(File.join(agent_dir, "openclaw-agent.sqlite"))

      {
        "id" => id,
        "workspace" => Dir.exist?(ws) ? "present" : "missing",
        "files" => files,
        "skills" => skills,
        "model" => resolve_model(defaults, models),
        "entry_extra" => entry.reject { |k, _| %w[id workspace].include?(k) },
        "sessions" => { "jsonl" => jsonl, "sqlite_bytes" => sqlite_bytes }
      }
    end

    agents.each { |a| a["secrets"] = detect_secrets(root, a, creds) }

    { "state" => root, "defaults" => defaults, "credentials" => creds, "agents" => agents }
  end

  # ---------- analyze ----------

  def analyze(dir, json: false)
    state = read_state(dir)
    if json
      puts JSON.pretty_generate(state)
      return state
    end
    print_report(state)
    state
  end

  def print_report(state)
    d = state["defaults"]
    dmodel = (d["model"] || {})
    puts "OpenClaw state: #{state['state']}"
    puts "Agents: #{state['agents'].size}  credentials: #{state['credentials'].size}"
    puts "Defaults: model #{dmodel['primary'] || '(none)'}  fallbacks: #{dmodel['fallbacks']&.join(', ')}  timeoutSeconds: #{d['timeoutSeconds']}"
    mapped = MAPPED_DEFAULT_KEYS
    archived = d.keys.reject { |k| mapped.include?(k) }
    puts "Defaults mapped:   #{mapped.join(', ')}"
    puts "Defaults archived: #{archived.sort.join(', ')}" unless archived.empty?
    puts
    state["agents"].each do |a|
      print_agent(a)
    end
  end

  def print_agent(a)
    migrated, archived = classify_files(a["files"])
    puts "agent #{a['id']}"
    puts "  workspace: #{a['workspace']}"
    puts "  prompt files: #{migrated.join(', ')}" unless migrated.empty?
    puts "  archived files (no equivalent): #{archived.join(', ')}" unless archived.empty?
    unless a["skills"].empty?
      skills = a["skills"].map { |s| "#{s['name']} (#{s['shared'] ? 'shared' : 'own'})" }
      puts "  skills: #{skills.join(', ')}"
    end
    m = a["model"]
    puts "  model: #{m['primary'] || '(none)'} (#{m['source']})" \
         "#{m['fallbacks'].empty? ? '' : '  fallbacks: ' + m['fallbacks'].join(', ')}"
    s = a["sessions"]
    puts "  sessions: #{s['jsonl']} jsonl#{s['sqlite_bytes'] ? ", sqlite #{human_bytes(s['sqlite_bytes'])}" : ''}"
    unless a["secrets"].empty?
      named = a["secrets"].map do |f|
        f["kind"] == "ref" ? "#{f['file']} (#{f['ref']})" : "#{f['file']} (#{f['credential']} value)"
      end
      puts "  secrets (named, never printed): #{named.join(', ')}"
    end
    extra = a["entry_extra"]
    puts "  agent-entry extras (archived on convert): #{extra.keys.join(', ')}" unless extra.empty?
    puts
  end

  def human_bytes(bytes)
    return "0 B" if bytes.nil?

    units = %w[B KB MB GB]
    value = bytes.to_f
    units.each do |u|
      return format("%.1f %s", value, u) if value < 1024 || u == units.last

      value /= 1024
    end
  end

  # ---------- convert ----------

  def convert(dir, agent:, out:, tools_from: nil, skill_conflict: "skip", migrate_secrets: false)
    state = read_state(dir)
    a = state["agents"].find { |x| x["id"] == agent } or
      raise Error, "agent '#{agent}' not found in #{state['state']}"
    raise Error, "workspace missing for '#{agent}' in #{state['state']}" if a["workspace"] == "missing"
    unless %w[skip overwrite rename].include?(skill_conflict)
      raise Error, "--skill-conflict must be skip|overwrite|rename, got '#{skill_conflict}'"
    end
    unless migrate_secrets || a["secrets"].empty?
      listing = a["secrets"].map { |f| "  #{f['file']}: #{f['kind'] == 'ref' ? f['ref'] : "credential '#{f['credential']}' value"}" }
      raise Error, "secrets detected in files to migrate — refusing (rerun with --migrate-secrets " \
                   "to keep placeholders, never values):\n#{listing.join("\n")}"
    end

    ws = File.join(state["state"], "workspace", agent)
    migrated_files, archived_files = classify_files(a["files"])
    root = state["state"]

    FileUtils.mkdir_p(File.join(out, "skills"))
    FileUtils.mkdir_p(File.join(out, ".archive"))

    migrated_files.each do |name|
      text = File.read(File.join(ws, name), encoding: "UTF-8")
      text = scrub_secrets(text, root, state["credentials"]) if migrate_secrets
      File.write(File.join(out, name), text)
    end

    outcomes = a["skills"].map do |s|
      src = File.join(ws, "skills", s["name"], "SKILL.md")
      dst = File.join(out, "skills", s["name"], "SKILL.md")
      text = File.read(src, encoding: "UTF-8")
      text = scrub_secrets(text, root, state["credentials"]) if migrate_secrets
      FileUtils.mkdir_p(File.dirname(dst))
      [dst, text, s["name"], write_with_conflict(dst, text, skill_conflict)]
    end

    tool_count = copy_tools(out, tools_from)

    provider, model = split_model_ref(a["model"]["primary"])
    config = { "id" => agent }
    config["provider"] = provider if provider
    config["model"] = model if model
    limits = {}
    timeout = state["defaults"]["timeoutSeconds"]
    limits["turn_timeout"] = timeout if timeout.is_a?(Integer) && timeout.positive?
    limits["context_budget"] = CONTEXT_BUDGET
    config["limits"] = limits
    reasoning = a["entry_extra"]["reasoningDefault"]
    config["params"] = { "thinking" => reasoning } if reasoning
    File.write(File.join(out, "agent.config.json"), JSON.pretty_generate(config) + "\n")

    archive_rest(ws, out, archived_files, state, agent)

    report = {
      "agent" => agent,
      "mapped_files" => migrated_files,
      "archived_files" => archived_files,
      "skills" => outcomes.map { |dst, _text, name, result| { "name" => name, "result" => result } },
      "tools_from" => tools_from,
      "tool_count" => tool_count,
      "model" => a["model"],
      "limits" => limits,
      "archived_defaults" => state["defaults"].keys.reject { |k| MAPPED_DEFAULT_KEYS.include?(k) }.sort,
      "secrets" => a["secrets"],
      "notes" => [
        "context_budget set to #{CONTEXT_BUDGET} (OpenClaw bootstrapMaxChars has no token equivalent; matches hand-built store packs)",
        tool_count.zero? ? "no tools: TOOLS.md is prose and cannot be derived; pass --tools-from to seed tools/*.json" : nil
      ].compact
    }
    File.write(File.join(out, ".report.json"), JSON.pretty_generate(report) + "\n")
    report
  end

  def scrub_secrets(text, root, cred_names)
    credential_values(root, cred_names).each do |value|
      name = owner_of(value, cred_names, root)
      text = text.gsub(value, "${#{File.basename(name.to_s, '.*').upcase}}")
    end
    text
  end

  def write_with_conflict(dst, text, mode)
    unless File.exist?(dst)
      File.write(dst, text)
      return :written
    end

    case mode
    when "skip"
      :skipped
    when "overwrite"
      File.write(dst, text)
      :overwritten
    when "rename"
      skills_dir = File.dirname(File.dirname(dst))
      base = File.basename(File.dirname(dst))
      n = 2
      n += 1 while File.exist?(File.join(skills_dir, "#{base}-#{n}", "SKILL.md"))
      renamed = File.join(skills_dir, "#{base}-#{n}", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(renamed))
      File.write(renamed, text)
      :renamed
    end
  end

  def copy_tools(out, tools_from)
    return 0 unless tools_from && Dir.exist?(File.join(tools_from, "tools"))

    FileUtils.mkdir_p(File.join(out, "tools"))
    files = Dir.glob(File.join(tools_from, "tools", "*.json")).sort
    files.each { |f| FileUtils.cp(f, File.join(out, "tools", File.basename(f))) }
    files.size
  end

  def archive_rest(ws, out, archived_files, state, agent)
    archived_files.each { |name| FileUtils.cp(File.join(ws, name), File.join(out, ".archive", name)) }
    File.write(File.join(out, ".archive", "openclaw-defaults.json"),
               JSON.pretty_generate(state["defaults"]) + "\n")
    models = read_json(File.join(state["state"], "agents", agent, "agent", "models.json"))
    File.write(File.join(out, ".archive", "agent-models.json"), JSON.pretty_generate(models) + "\n") if models
    entry = state["agents"].find { |a| a["id"] == agent }
    extra = entry && entry["entry_extra"]
    if extra && !extra.empty?
      File.write(File.join(out, ".archive", "openclaw-agent-entry.json"), JSON.pretty_generate(extra) + "\n")
    end
    return if state["credentials"].empty?

    File.write(File.join(out, ".archive", "credentials.names.txt"), state["credentials"].join("\n") + "\n")
  end

  # ---------- CLI ----------

  USAGE = <<~USAGE
    usage: migrate_openclaw.rb analyze <state-dir> [--json]
           migrate_openclaw.rb convert <state-dir> --agent <id> --out <dir>
                              [--tools-from <pack-dir>] [--skill-conflict skip|overwrite|rename]
                              [--migrate-secrets]
           migrate_openclaw.rb import <pack-dir>
  USAGE

  def cli(argv)
    # analyze is the default subcommand: a bare state-dir argument means analyze.
    cmd = %w[analyze convert import].include?(argv.first) ? argv.shift : "analyze"
    case cmd
    when "analyze"
      options = {}
      OptionParser.new do |o|
        o.on("--json") { options[:json] = true }
        o.on("-h", "--help") { puts USAGE; exit 0 }
      end.parse!(argv)
      dir = argv.shift or abort(USAGE)
      analyze(dir, json: options[:json])
    when "convert"
      options = { skill_conflict: "skip", migrate_secrets: false }
      OptionParser.new do |o|
        o.on("--agent ID") { |v| options[:agent] = v }
        o.on("--out DIR") { |v| options[:out] = v }
        o.on("--tools-from DIR") { |v| options[:tools_from] = v }
        o.on("--skill-conflict MODE", %w[skip overwrite rename]) { |v| options[:skill_conflict] = v }
        o.on("--migrate-secrets") { options[:migrate_secrets] = true }
        o.on("-h", "--help") { puts USAGE; exit 0 }
      end.parse!(argv)
      dir = argv.shift or abort(USAGE)
      abort(USAGE) unless options[:agent] && options[:out]
      convert(dir, **options)
    when "import"
      pack = argv.shift or abort(USAGE)
      import_pack = File.expand_path("import_pack.rb", __dir__)
      exec RbConfig.ruby, import_pack, pack
    else
      abort(USAGE)
    end
  rescue Error => e
    abort("migrate_openclaw: #{e.message}")
  end
end

MigrateOpenclaw.cli(ARGV) if $PROGRAM_NAME == __FILE__

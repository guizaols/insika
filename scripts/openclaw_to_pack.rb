# frozen_string_literal: true

# MIGRATION UTILITY (one-off, OUTSIDE the product — techspec Phase 7 §4 D7).
# Converts the tools of the OpenClaw plugin `acheib2b-tools-dev` into harness
# data-tools (tools/<name>.json), reading the SOURCE OF TRUTH (the `.ts`) — name, endpoint
# slug (`callAgentTool("<slug>")`), description and TOP-LEVEL params of the
# `Type.Object({...})` (TypeBox). It is IDEMPOTENT/re-runnable: regenerates the files
# on each run, so you can re-provision when the database is recreated in the
# tests (run this + `import_pack.rb`).
#
# NOT part of the engine (it's specific to the current OpenClaw product). Uses stdlib only.
#
# Usage:
#   ruby scripts/openclaw_to_pack.rb <plugin_dir> <out_tools_dir> [name1 name2 ...]
#     - <plugin_dir>: .../openclaw/extensions/acheib2b-tools-dev (or env OPENCLAW_PLUGIN_DIR)
#     - <out_tools_dir>: where to write the tools/*.json (e.g.: ~/pack/cacau-show/tools)
#     - [names]: only those tools. Without names: REFRESH (regenerates the *.json already
#                present in out_dir); if out_dir is empty, generates ALL the ones
#                registered in index.ts.
#   Env: ACHEI_INTERNAL_URL (default http://localhost:3000) — base of /api/internal.

require "json"
require "fileutils"

plugin_dir = ARGV[0] || ENV["OPENCLAW_PLUGIN_DIR"] or
  abort("usage: openclaw_to_pack.rb <plugin_dir> <out_tools_dir> [names...]")
out_dir = ARGV[1] or abort("usage: openclaw_to_pack.rb <plugin_dir> <out_tools_dir> [names...]")
wanted = ARGV[2..] || []
base_url = ENV.fetch("ACHEI_INTERNAL_URL", "http://localhost:3000")
TOKEN_PLACEHOLDER = "__BIA_INTERNAL_API_TOKEN__"

tools_src = File.join(plugin_dir, "tools")
index_ts = File.join(plugin_dir, "index.ts")
abort("plugin without tools/ in #{plugin_dir}") unless Dir.exist?(tools_src)
abort("plugin without index.ts in #{plugin_dir}") unless File.exist?(index_ts)

# --- discovers the REGISTERED tools (index.ts): factory -> file + only the ones used
# in api.registerTool(...). Non-registered files (e.g.: dormant Natura ones) are left
# out.
index = File.read(index_ts)
factory_file = index.scan(/import\s*\{\s*(create\w+)\s*\}\s*from\s*"\.\/tools\/([\w-]+)\.js"/)
                    .to_h # createXxx => "file-name"
registered = index.scan(/(create\w+Tool)\(resolveCtx/).flatten.uniq
registered_files = registered.filter_map { |f| factory_file[f] }.uniq

# --- parse ONE .ts -> descriptor {name, slug, description, params[]}
# JS string literal (single OR double quotes; the .ts mix both styles).
JS_STR = /(['"])((?:\\.|(?!\1).)*)\1/

def parse_tool(path)
  src = File.read(path)
  name = src[/name:\s*#{JS_STR}/, 2]
  slug = src[/callAgentTool\(\s*#{JS_STR}/, 2]
  # description of the tool OBJECT (the factory's, inside the `return {`); fallback:
  # the 1st description in the file.
  desc = src[/return\s*\{.*?description:\s*\n?\s*#{JS_STR}/m, 2] ||
         src[/description:\s*\n?\s*#{JS_STR}/m, 2]
  { name: name, slug: slug, description: unescape(desc.to_s), params: parse_params(src) }
end

# Block `const parameters = Type.Object({ <inner> \n});` -> top-level params (2 spaces).
def parse_params(src)
  inner = src[/const parameters = Type\.Object\(\{\n(.*?)\n\}\);/m, 1]
  return [] if inner.nil? || inner.strip.empty? # Type.Object({}) -> no params

  lines = inner.lines
  # indices of the TOP-LEVEL keys (exactly 2 spaces of indentation)
  key_idx = lines.each_index.select { |i| lines[i] =~ /\A {2}(\w+):/ }
  key_idx.each_with_index.map do |start, n|
    stop = key_idx[n + 1] || lines.length
    block = lines[start...stop].join
    key = block[/\A {2}(\w+):/, 1]
    optional = block =~ /\A {2}\w+:\s*Type\.Optional\(/
    kind = block.scan(/Type\.(String|Number|Integer|Boolean|Array|Object)/).flatten.first
    desc = block[/description:\s*\n?\s*#{JS_STR}/m, 2]
    { name: key, type: harness_type(kind), required: optional.nil?, description: unescape(desc.to_s) }
  end
end

def harness_type(kind)
  case kind
  when "String" then "string"
  when "Number", "Integer" then "number"
  when "Boolean" then "boolean"
  when "Array" then "array"
  else
    warn "  [warning] TypeBox type '#{kind.inspect}' has no flat mapping -> string" unless kind == "String"
    "string"
  end
end

def unescape(str)
  str.gsub('\\"', '"').gsub("\\'", "'").gsub("\\n", " ").gsub(/\s+/, " ").strip
end

# body template: string -> "k":"{{k}}"; number/boolean/array -> "k":{{k}}.
def body_for(params)
  return "{}" if params.empty?

  pairs = params.map do |p|
    ph = "{{#{p[:name]}}}"
    p[:type] == "string" ? %("#{p[:name]}":"#{ph}") : %("#{p[:name]}":#{ph})
  end
  "{#{pairs.join(',')}}"
end

# reads (search_/get_/list_) are not side-effects (safe to re-run on resume).
def side_effect_for(name) = name !~ /\A(search|get|list)_/

def tool_json(tool, base_url)
  {
    "name" => tool[:name],
    "description" => tool[:description],
    "parameters" => tool[:params].map do |p|
      { "name" => p[:name], "type" => p[:type],
        "description" => p[:description].empty? ? p[:name] : p[:description], "required" => p[:required] }
    end,
    "request" => {
      "method" => "POST",
      "url" => "#{base_url}/api/internal/agent_tools/#{tool[:slug]}",
      "headers" => {
        "X-Chat-Id" => "{{ctx.chat_id}}", "X-Store-Id" => "{{ctx.store_id}}",
        "X-Agent-Id" => "{{ctx.agent_id}}", "Authorization" => "Bearer #{TOKEN_PLACEHOLDER}",
        "Content-Type" => "application/json"
      },
      "body" => body_for(tool[:params])
    },
    "response" => { "extract" => "body_raw" },
    "secret_headers" => ["Authorization"],
    "side_effect" => side_effect_for(tool[:name])
  }
end

# --- catalog: parse every registered file -> name => tool
catalog = registered_files.each_with_object({}) do |file, acc|
  path = File.join(tools_src, "#{file}.ts")
  next unless File.exist?(path)

  t = parse_tool(path)
  next warn("  [warning] #{file}.ts without name/slug — skipped") if t[:name].nil? || t[:slug].nil?

  acc[t[:name]] = t
end

# --- decide the set to generate
existing = Dir.glob(File.join(out_dir, "*.json")).map { |f| File.basename(f, ".json") }
names =
  if !wanted.empty? then wanted
  elsif !existing.empty? then existing            # REFRESH what already exists
  else catalog.keys                               # everything registered
  end

FileUtils.mkdir_p(out_dir)
written = []
missing = []
names.each do |name|
  tool = catalog[name]
  next (missing << name) if tool.nil?

  File.write(File.join(out_dir, "#{name}.json"), JSON.pretty_generate(tool_json(tool, base_url)) + "\n")
  written << name
end

puts "plugin: #{plugin_dir}"
puts "registered in index.ts: #{catalog.size} tools"
puts "generated in #{out_dir}: #{written.size} (#{written.sort.join(', ')})"
warn "NOT found in the plugin (check the name): #{missing.sort.join(', ')}" unless missing.empty?
puts
puts "next: bundle exec ruby scripts/import_pack.rb #{File.dirname(out_dir)}  (with BIA_INTERNAL_API_TOKEN=…)"

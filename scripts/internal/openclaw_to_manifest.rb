# frozen_string_literal: true

# MIGRATION UTILITY (one-off, OUTSIDE the product — techspec Phase 7 §4 D7 / task 7).
# Reads the OpenClaw plugin `acheib2b-tools-dev` (the SOURCE OF TRUTH: the `.ts`) and emits
# a SINGLE `manifesto.json` in the Step B format (defaults + tools[]), consumable
# by `Harness::ToolManifest.from_h(...).tool_definitions(secrets:, env:)`.
#
# Differs from `openclaw_to_pack.rb` (OLD format: N per-tool files, FLAT
# params): here the output is a SINGLE manifest and the params come out as truly
# NESTED JSON Schema — TypeBox's `Type.Object({...})` already IS JSON Schema, so
# a recursive TypeBox parser (String/Number/Integer/Boolean/Array/Object/
# Optional) reconstructs the full schema (e.g.: `search_products.query_filter_pairs`
# = array of objects {query, filters}). Types outside this subset degrade to string
# with a warning (none of the current 44 tools uses an exotic construct).
#
# GENERIC in the engine, specific HERE (NF1): `lib/harness` never mentions achei/
# openclaw — this script is disposable, lives in `scripts/` and uses stdlib only.
# It is IDEMPOTENT: regenerates the whole manifest on each run.
#
# Each tool's `endpoint` is the slug of `callAgentTool("<slug>")` — DATA, never
# inferred from the name (R6): e.g. send_finalize_button→finalize_button,
# search_faq→search_faqs, call_support→support_requests, search_voucher→
# search_vouchers. The `group` is derived by name convention (OpenClaw doesn't
# persist groups — derives by suffix at runtime); here it becomes DATA (Step C).
#
# The SECRET never enters the manifest: the Authorization references
# `{{secret.BIA_INTERNAL_API_TOKEN}}`, resolved only at INGESTION (D6/R3).
#
# Usage:
#   ruby scripts/openclaw_to_manifest.rb [<plugin_dir>] [<out_file>]
#     - <plugin_dir>: .../openclaw/extensions/acheib2b-tools-dev
#                     (default: env OPENCLAW_PLUGIN_DIR, else the known path)
#     - <out_file>  : output file (default: manifesto.json in the current directory)
#
# Do NOT version the real output (it's derived from the client's product).

require "json"

# OpenClaw plugin -> manifest converter. Module of functions (stateless) so it's
# testable (the spec does `require` and calls #build_manifest over a small fixture)
# AND executable (CLI guard at the end of the file).
module OpenclawToManifest
  module_function

  # Known path of the source of truth (only used in CLI mode, as a fallback).
  DEFAULT_PLUGIN_DIR =
    "/Users/guizaols/projetos/tedi/openclaw/openclaw/extensions/acheib2b-tools-dev"

  # Common binding of the 44 tools (achei-b2b exposes everything at POST /api/internal/
  # agent_tools/<slug>, with the turn's ids in X-*-Id headers and the internal token in the
  # Authorization). Inherited by EVERY tool via the manifest's `defaults`.
  DEFAULTS = {
    "base_url" => "{{env.ACHEI_INTERNAL_URL}}",
    "path_template" => "/api/internal/agent_tools/{endpoint}",
    "method" => "POST",
    "headers" => {
      "X-Chat-Id" => "{{ctx.chat_id}}",
      "X-Store-Id" => "{{ctx.store_id}}",
      "X-Agent-Id" => "{{ctx.agent_id}}",
      "Authorization" => "Bearer {{secret.BIA_INTERNAL_API_TOKEN}}",
      "Content-Type" => "application/json"
    },
    "secret_headers" => ["Authorization"],
    "response" => { "extract" => "body_raw" }
  }.freeze

  # Groups as DATA (Step C/D4). OpenClaw derives by name/suffix convention
  # at runtime; we replicate that convention here to write the group explicitly.
  # List/DC tools shared by the Groceries V2 vertical (no suffix).
  GROCERIES_SHARED = %w[
    save_shopping_list remove_from_list update_list_quantity switch_distribution_center
  ].freeze
  # Cross-cutting/institutional tools (FAQ, voucher, orders, support): core group.
  CORE_TOOLS = %w[search_faq search_voucher apply_voucher search_orders call_support].freeze

  # JS string literal (single OR double quotes; the .ts mix both styles).
  JS_STR = /(['"])((?:\\.|(?!\1).)*)\1/

  # === public API ==========================================================

  # <plugin_dir> -> manifest Hash (version/defaults/tools). Only the tools
  # REGISTERED in index.ts enter (dormant files are left out), mirroring
  # `openclaw_to_pack.rb`.
  def build_manifest(plugin_dir)
    tools_src = File.join(plugin_dir, "tools")
    tools = registered_files(plugin_dir).filter_map do |file|
      path = File.join(tools_src, "#{file}.ts")
      next unless File.exist?(path)

      tool = parse_tool(path)
      next warn("  [warning] #{file}.ts without name/slug — skipped") if tool[:name].nil? || tool[:slug].nil?

      tool_entry(tool)
    end
    { "version" => 1, "defaults" => DEFAULTS, "tools" => tools }
  end

  # === registered tools discovery ==========================================

  # index.ts: factory createXxx -> file, filtered by those appearing in
  # api.registerTool(...). Identical to openclaw_to_pack (same source of truth).
  def registered_files(plugin_dir)
    index = File.read(File.join(plugin_dir, "index.ts"))
    factory_file = index.scan(/import\s*\{\s*(create\w+)\s*\}\s*from\s*"\.\/tools\/([\w-]+)\.js"/).to_h
    registered = index.scan(/(create\w+Tool)\(resolveCtx/).flatten.uniq
    registered.filter_map { |factory| factory_file[factory] }.uniq
  end

  # === parse ONE .ts =======================================================

  # -> { name, slug, description, parameters: <JSON Schema> }
  def parse_tool(path)
    src = File.read(path)
    name = src[/name:\s*#{JS_STR}/, 2]
    slug = src[/callAgentTool\(\s*#{JS_STR}/, 2]
    # description of the tool OBJECT (inside the `return {`); fallback: the file's 1st.
    desc = src[/return\s*\{.*?description:\s*\n?\s*#{JS_STR}/m, 2] ||
           src[/description:\s*\n?\s*#{JS_STR}/m, 2]
    { name: name, slug: slug, description: unescape(desc.to_s), parameters: parse_parameters(src) }
  end

  # === TypeBox -> JSON Schema (recursive parser) ===========================
  # `const parameters = Type.Object({...});` is the root. Type.Object already IS JSON
  # Schema; we only need to reconstruct it as a nested Hash within the ToolDefinition's
  # safe subset (object/array/string/number/integer/boolean + description/
  # min*/max*/additionalProperties). Type.Optional only affects the parent's `required`.

  def empty_schema = { "type" => "object", "properties" => {}, "required" => [] }

  def parse_parameters(src)
    at = src.match(/const\s+parameters\s*=\s*/)
    return empty_schema if at.nil?

    expr = extract_type_expr(src, at.end(0))
    return empty_schema if expr.nil?

    parse_type(expr)
  end

  # Starting at `from`, isolates the whole `Type.X( ... )` expression (balanced
  # parentheses) — the root of the schema.
  def extract_type_expr(src, from)
    idx = src.index("Type.", from)
    return nil if idx.nil?

    open = src.index("(", idx)
    close = open && match_delim(src, open)
    return nil if open.nil? || close.nil?

    src[idx..close]
  end

  # A `Type.Kind(<args>)` expression -> JSON Schema Hash. Kind outside the subset
  # degrades to string with a warning (R1).
  def parse_type(expr)
    expr = expr.strip
    m = expr.match(/\AType\.(\w+)/)
    return degrade(expr) if m.nil?

    kind = m[1]
    rest = expr[m.end(0)..].lstrip
    return degrade(expr, kind) unless rest.start_with?("(")

    close = match_delim(rest, 0)
    args = rest[1...close].strip

    case kind
    when "Optional" then parse_type(args)           # unwraps; required belongs to the parent
    when "Object"   then parse_object(args)
    when "Array"    then parse_array(args)
    when "String"   then scalar("string", args)
    when "Number"   then scalar("number", args)
    when "Integer"  then scalar("integer", args)
    when "Boolean"  then scalar("boolean", args)
    else degrade(expr, kind)
    end
  end

  def scalar(type, opts)
    apply_opts!({ "type" => type }, opts)
  end

  # Type.Array(<inner>[, <opts>]) -> { type: array, items: <inner>, min/maxItems }.
  def parse_array(args)
    inner, opts = split_top_level(args)
    schema = { "type" => "array", "items" => parse_type(inner.to_s) }
    apply_opts!(schema, opts)
  end

  # Type.Object({<props>}[, <opts>]) -> { type: object, properties, required, ... }.
  # A field whose value is Type.Optional(...) does NOT enter `required`.
  def parse_object(args)
    props_literal, opts = split_top_level(args)
    schema = { "type" => "object", "properties" => {}, "required" => [] }
    each_object_field(props_literal.to_s) do |key, value_expr|
      optional = value_expr.lstrip.start_with?("Type.Optional")
      schema["properties"][key] = parse_type(value_expr)
      schema["required"] << key unless optional
    end
    apply_opts!(schema, opts)
  end

  # Unknown Type (outside the subset): degrades to string, warning (R1). None
  # of the current 44 tools lands here — it's just a safety net for the future.
  def degrade(expr, kind = nil)
    label = kind || expr[/\AType\.(\w+)/, 1] || expr[0, 20]
    warn "  [warning] TypeBox '#{label}' outside the safe subset -> degraded to string"
    { "type" => "string" }
  end

  # Extracts description/min*/max*/additionalProperties from an options `{ ... }`
  # literal (or empty string / nil). Only subset keys; the rest is ignored.
  def apply_opts!(schema, opts)
    opts = opts.to_s
    return schema if opts.empty?

    if (desc = opts[/description:\s*\n?\s*#{JS_STR}/m, 2])
      schema["description"] = unescape(desc)
    end
    %w[minItems maxItems minLength maxLength minimum maximum].each do |key|
      next unless (val = opts[/\b#{key}:\s*(-?\d+(?:\.\d+)?)/, 1])

      schema[key] = val.include?(".") ? val.to_f : val.to_i
    end
    if (ap = opts[/additionalProperties:\s*(true|false)/, 1])
      schema["additionalProperties"] = (ap == "true")
    end
    schema
  end

  # === parsing helpers (balancing/split) ===================================

  # Index of the closing delimiter matching the one opened at `open_idx`,
  # ignoring delimiters inside JS strings.
  def match_delim(str, open_idx)
    pairs = { "(" => ")", "{" => "}", "[" => "]" }
    open = str[open_idx]
    close = pairs.fetch(open)
    depth = 0
    in_str = nil
    i = open_idx
    while i < str.length
      c = str[i]
      if in_str
        if c == "\\" then i += 2; next end

        in_str = nil if c == in_str
      elsif ['"', "'", "`"].include?(c)
        in_str = c
      elsif c == open
        depth += 1
      elsif c == close
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  # Splits `s` on the TOP-LEVEL commas (outside (), {}, [] and strings).
  def split_top_level(str)
    parts = []
    buf = +""
    depth = 0
    in_str = nil
    i = 0
    while i < str.length
      c = str[i]
      if in_str
        buf << c
        if c == "\\"
          buf << str[i + 1].to_s
          i += 2
          next
        end
        in_str = nil if c == in_str
      elsif ['"', "'", "`"].include?(c)
        in_str = c
        buf << c
      elsif "([{".include?(c)
        depth += 1
        buf << c
      elsif ")]}".include?(c)
        depth -= 1
        buf << c
      elsif c == "," && depth.zero?
        parts << buf.strip
        buf = +""
      else
        buf << c
      end
      i += 1
    end
    parts << buf.strip unless buf.strip.empty?
    parts
  end

  # Iterates the TOP-LEVEL `key: value` pairs of an object `{ ... }` literal.
  def each_object_field(literal)
    inner = strip_braces(literal)
    return if inner.strip.empty?

    split_top_level(inner).each do |field|
      colon = top_level_colon(field)
      next if colon.nil?

      key = field[0...colon].strip.gsub(/\A["']|["']\z/, "")
      value = field[(colon + 1)..].strip
      yield key, value
    end
  end

  # Position of the first TOP-LEVEL `:` (outside delimiters/strings) — separates
  # key from value in an object field.
  def top_level_colon(str)
    depth = 0
    in_str = nil
    i = 0
    while i < str.length
      c = str[i]
      if in_str
        if c == "\\" then i += 2; next end

        in_str = nil if c == in_str
      elsif ['"', "'", "`"].include?(c)
        in_str = c
      elsif "([{".include?(c)
        depth += 1
      elsif ")]}".include?(c)
        depth -= 1
      elsif c == ":" && depth.zero?
        return i
      end
      i += 1
    end
    nil
  end

  def strip_braces(str)
    str = str.strip
    str.start_with?("{") && str.end_with?("}") ? str[1..-2] : str
  end

  def unescape(str)
    str.gsub('\\"', '"').gsub("\\'", "'").gsub("\\n", " ").gsub(/\s+/, " ").strip
  end

  # === assembling the tool in the manifest =================================

  def tool_entry(tool)
    {
      "name" => tool[:name],
      "group" => group_for(tool[:name]),
      "endpoint" => tool[:slug], # callAgentTool slug — never inferred from the name (R6)
      "description" => tool[:description],
      "parameters" => tool[:parameters],
      "body" => body_template(tool[:parameters]),
      "side_effect" => side_effect_for(tool[:name])
    }
  end

  # Group by name convention (priority: natura/cacau > suffix > shared/core >
  # default). Mirrors OpenClaw's runtime derivation, now as DATA.
  def group_for(name)
    return "natura" if name.start_with?("natura_")
    return "cacau" if name.start_with?("cacau_")
    return "b2b" if name.end_with?("_b2b")
    return "groceries" if name.end_with?("_groceries") || GROCERIES_SHARED.include?(name)
    return "core" if CORE_TOOLS.include?(name)

    "default"
  end

  # reads (search_/get_/list_) are not side-effects (re-run on resume);
  # the rest mutates (same heuristic as openclaw_to_pack).
  def side_effect_for(name) = name !~ /\A(search|get|list)_/

  # Body template: forwards EVERY top-level param. Objects/arrays go whole
  # (`{{k}}` — the DataDefinedTool serializes the value to JSON); strings go quoted.
  # This is what reproduces the plugin's `callAgentTool("<slug>", params)` (full params).
  def body_template(schema)
    props = schema["properties"] || {}
    return "{}" if props.empty?

    pairs = props.map do |key, prop|
      placeholder = "{{#{key}}}"
      prop["type"] == "string" ? %("#{key}":"#{placeholder}") : %("#{key}":#{placeholder})
    end
    "{#{pairs.join(',')}}"
  end
end

# === CLI ===================================================================
# Guard: only runs when executed directly (the spec does `require` and calls the functions).
if $PROGRAM_NAME == __FILE__
  plugin_dir = ARGV[0] || ENV["OPENCLAW_PLUGIN_DIR"] || OpenclawToManifest::DEFAULT_PLUGIN_DIR
  out_file = ARGV[1] || "manifesto.json"

  abort("plugin without index.ts in #{plugin_dir}") unless File.exist?(File.join(plugin_dir, "index.ts"))

  manifest = OpenclawToManifest.build_manifest(plugin_dir)
  File.write(out_file, JSON.pretty_generate(manifest) + "\n")

  by_group = manifest["tools"].group_by { |t| t["group"] }.transform_values(&:size).sort.to_h
  puts "plugin:    #{plugin_dir}"
  puts "manifest:  #{out_file} (#{manifest['tools'].size} tools)"
  puts "groups:    #{by_group.map { |g, n| "#{g}=#{n}" }.join(', ')}"
end

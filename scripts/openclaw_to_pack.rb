# frozen_string_literal: true

# UTILITÁRIO DE MIGRAÇÃO (one-off, FORA do produto — techspec Fase 7 §4 D7).
# Converte as tools do plugin OpenClaw `acheib2b-tools-dev` em data-tools do
# harness (tools/<name>.json), lendo a FONTE DA VERDADE (os `.ts`) — name, slug
# do endpoint (`callAgentTool("<slug>")`), descrição e params TOP-LEVEL do
# `Type.Object({...})` (TypeBox). É IDEMPOTENTE/re-runnable: regenera os arquivos
# a cada execução, então dá pra re-provisionar quando o banco é recriado nos
# testes (rode este + `import_pack.rb`).
#
# NÃO faz parte do motor (é específico do produto OpenClaw atual). Usa só stdlib.
#
# Uso:
#   ruby scripts/openclaw_to_pack.rb <plugin_dir> <out_tools_dir> [nome1 nome2 ...]
#     - <plugin_dir>: .../openclaw/extensions/acheib2b-tools-dev (ou env OPENCLAW_PLUGIN_DIR)
#     - <out_tools_dir>: onde gravar os tools/*.json (ex.: ~/pack/cacau-show/tools)
#     - [nomes]: só essas tools. Sem nomes: REFRESH (regenera os *.json já
#                existentes no out_dir); se o out_dir estiver vazio, gera TODAS as
#                registradas no index.ts.
#   Env: ACHEI_INTERNAL_URL (default http://localhost:3000) — base do /api/internal.

require "json"
require "fileutils"

plugin_dir = ARGV[0] || ENV["OPENCLAW_PLUGIN_DIR"] or
  abort("uso: openclaw_to_pack.rb <plugin_dir> <out_tools_dir> [nomes...]")
out_dir = ARGV[1] or abort("uso: openclaw_to_pack.rb <plugin_dir> <out_tools_dir> [nomes...]")
wanted = ARGV[2..] || []
base_url = ENV.fetch("ACHEI_INTERNAL_URL", "http://localhost:3000")
TOKEN_PLACEHOLDER = "__BIA_INTERNAL_API_TOKEN__"

tools_src = File.join(plugin_dir, "tools")
index_ts = File.join(plugin_dir, "index.ts")
abort("plugin sem tools/ em #{plugin_dir}") unless Dir.exist?(tools_src)
abort("plugin sem index.ts em #{plugin_dir}") unless File.exist?(index_ts)

# --- descobre as tools REGISTRADAS (index.ts): factory -> arquivo + só as usadas
# em api.registerTool(...). Arquivos não-registrados (ex.: Natura dormentes) ficam
# de fora.
index = File.read(index_ts)
factory_file = index.scan(/import\s*\{\s*(create\w+)\s*\}\s*from\s*"\.\/tools\/([\w-]+)\.js"/)
                    .to_h # createXxx => "file-name"
registered = index.scan(/(create\w+Tool)\(resolveCtx/).flatten.uniq
registered_files = registered.filter_map { |f| factory_file[f] }.uniq

# --- parse de UM .ts -> descritor {name, slug, description, params[]}
# Literal de string JS (aspas simples OU duplas; os .ts misturam os dois estilos).
JS_STR = /(['"])((?:\\.|(?!\1).)*)\1/

def parse_tool(path)
  src = File.read(path)
  name = src[/name:\s*#{JS_STR}/, 2]
  slug = src[/callAgentTool\(\s*#{JS_STR}/, 2]
  # description do OBJETO da tool (a do factory, dentro do `return {`); fallback:
  # a 1ª description do arquivo.
  desc = src[/return\s*\{.*?description:\s*\n?\s*#{JS_STR}/m, 2] ||
         src[/description:\s*\n?\s*#{JS_STR}/m, 2]
  { name: name, slug: slug, description: unescape(desc.to_s), params: parse_params(src) }
end

# Bloco `const parameters = Type.Object({ <inner> \n});` -> params top-level (2 espaços).
def parse_params(src)
  inner = src[/const parameters = Type\.Object\(\{\n(.*?)\n\}\);/m, 1]
  return [] if inner.nil? || inner.strip.empty? # Type.Object({}) -> sem params

  lines = inner.lines
  # índices das chaves TOP-LEVEL (exatamente 2 espaços de indentação)
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
    warn "  [aviso] tipo TypeBox '#{kind.inspect}' sem mapeamento flat -> string" unless kind == "String"
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

# reads (search_/get_/list_) não são side-effect (podem reexecutar no resume).
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

# --- catálogo: parse de todos os arquivos registrados -> name => tool
catalog = registered_files.each_with_object({}) do |file, acc|
  path = File.join(tools_src, "#{file}.ts")
  next unless File.exist?(path)

  t = parse_tool(path)
  next warn("  [aviso] #{file}.ts sem name/slug — pulado") if t[:name].nil? || t[:slug].nil?

  acc[t[:name]] = t
end

# --- decide o conjunto a gerar
existing = Dir.glob(File.join(out_dir, "*.json")).map { |f| File.basename(f, ".json") }
names =
  if !wanted.empty? then wanted
  elsif !existing.empty? then existing            # REFRESH do que já existe
  else catalog.keys                               # tudo registrado
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
puts "registradas no index.ts: #{catalog.size} tools"
puts "geradas em #{out_dir}: #{written.size} (#{written.sort.join(', ')})"
warn "NÃO encontradas no plugin (verifique o nome): #{missing.sort.join(', ')}" unless missing.empty?
puts
puts "próximo: bundle exec ruby scripts/import_pack.rb #{File.dirname(out_dir)}  (com BIA_INTERNAL_API_TOKEN=…)"

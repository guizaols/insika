# frozen_string_literal: true

# UTILITÁRIO DE MIGRAÇÃO (one-off, FORA do produto — techspec Fase 7 §4 D7 / task 7).
# Lê o plugin OpenClaw `acheib2b-tools-dev` (a FONTE DA VERDADE: os `.ts`) e emite
# UM `manifesto.json` único no formato da Etapa B (defaults + tools[]), consumível
# por `Harness::ToolManifest.from_h(...).tool_definitions(secrets:, env:)`.
#
# Difere do `openclaw_to_pack.rb` (formato ANTIGO: N arquivos por-tool, params
# PLANOS): aqui a saída é um manifesto ÚNICO e os params saem como JSON Schema
# ANINHADO de verdade — o `Type.Object({...})` do TypeBox já É JSON Schema, então
# um parser recursivo do TypeBox (String/Number/Integer/Boolean/Array/Object/
# Optional) reconstrói o schema completo (ex.: `search_products.query_filter_pairs`
# = array de objetos {query, filters}). Tipos fora desse subset degradam p/ string
# com aviso (nenhum dos 44 tools atuais usa construção exótica).
#
# GENÉRICO no motor, específico AQUI (NF1): o `lib/harness` nunca cita achei/
# openclaw — este script é descartável, vive em `scripts/` e usa só stdlib.
# É IDEMPOTENTE: regenera o manifesto inteiro a cada execução.
#
# O `endpoint` de cada tool é o slug do `callAgentTool("<slug>")` — DADO, nunca
# inferido do name (R6): p.ex. send_finalize_button→finalize_button,
# search_faq→search_faqs, call_support→support_requests, search_voucher→
# search_vouchers. O `group` é derivado por convenção de nome (o OpenClaw não
# persiste grupos — deriva por sufixo em runtime); aqui vira DADO (Etapa C).
#
# O SEGREDO nunca entra no manifesto: a Authorization referencia
# `{{secret.BIA_INTERNAL_API_TOKEN}}`, resolvido só na INGESTÃO (D6/R3).
#
# Uso:
#   ruby scripts/openclaw_to_manifest.rb [<plugin_dir>] [<out_file>]
#     - <plugin_dir>: .../openclaw/extensions/acheib2b-tools-dev
#                     (default: env OPENCLAW_PLUGIN_DIR, senão o caminho conhecido)
#     - <out_file>  : arquivo de saída (default: manifesto.json no diretório atual)
#
# NÃO versione a saída real (é derivada do produto do cliente).

require "json"

# Conversor plugin OpenClaw -> manifesto. Módulo de funções (sem estado) p/ ser
# testável (o spec dá `require` e chama #build_manifest sobre um fixture pequeno)
# E executável (guard de CLI no fim do arquivo).
module OpenclawToManifest
  module_function

  # Caminho conhecido da fonte da verdade (só usado no modo CLI, como fallback).
  DEFAULT_PLUGIN_DIR =
    "/Users/guizaols/projetos/tedi/openclaw/openclaw/extensions/acheib2b-tools-dev"

  # Binding comum das 44 tools (o achei-b2b expõe tudo em POST /api/internal/
  # agent_tools/<slug>, com os ids do turno em headers X-*-Id e o token interno na
  # Authorization). Herdado por TODA tool via `defaults` do manifesto.
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

  # Grupos como DADO (Etapa C/D4). O OpenClaw deriva por convenção de nome/sufixo
  # em runtime; replicamos essa convenção aqui p/ gravar o grupo explicitamente.
  # Tools de lista/CD compartilhadas pela vertical Groceries V2 (sem sufixo).
  GROCERIES_SHARED = %w[
    save_shopping_list remove_from_list update_list_quantity switch_distribution_center
  ].freeze
  # Tools transversais/institucionais (FAQ, cupom, pedidos, suporte): grupo core.
  CORE_TOOLS = %w[search_faq search_voucher apply_voucher search_orders call_support].freeze

  # Literal de string JS (aspas simples OU duplas; os .ts misturam os dois estilos).
  JS_STR = /(['"])((?:\\.|(?!\1).)*)\1/

  # === API pública =========================================================

  # <plugin_dir> -> Hash do manifesto (version/defaults/tools). Só as tools
  # REGISTRADAS no index.ts entram (arquivos dormentes ficam de fora), espelhando
  # o `openclaw_to_pack.rb`.
  def build_manifest(plugin_dir)
    tools_src = File.join(plugin_dir, "tools")
    tools = registered_files(plugin_dir).filter_map do |file|
      path = File.join(tools_src, "#{file}.ts")
      next unless File.exist?(path)

      tool = parse_tool(path)
      next warn("  [aviso] #{file}.ts sem name/slug — pulado") if tool[:name].nil? || tool[:slug].nil?

      tool_entry(tool)
    end
    { "version" => 1, "defaults" => DEFAULTS, "tools" => tools }
  end

  # === descoberta das tools registradas ====================================

  # index.ts: factory createXxx -> arquivo, filtrado pelas que aparecem em
  # api.registerTool(...). Idêntico ao openclaw_to_pack (mesma fonte da verdade).
  def registered_files(plugin_dir)
    index = File.read(File.join(plugin_dir, "index.ts"))
    factory_file = index.scan(/import\s*\{\s*(create\w+)\s*\}\s*from\s*"\.\/tools\/([\w-]+)\.js"/).to_h
    registered = index.scan(/(create\w+Tool)\(resolveCtx/).flatten.uniq
    registered.filter_map { |factory| factory_file[factory] }.uniq
  end

  # === parse de UM .ts =====================================================

  # -> { name, slug, description, parameters: <JSON Schema> }
  def parse_tool(path)
    src = File.read(path)
    name = src[/name:\s*#{JS_STR}/, 2]
    slug = src[/callAgentTool\(\s*#{JS_STR}/, 2]
    # description do OBJETO da tool (dentro do `return {`); fallback: a 1ª do arquivo.
    desc = src[/return\s*\{.*?description:\s*\n?\s*#{JS_STR}/m, 2] ||
           src[/description:\s*\n?\s*#{JS_STR}/m, 2]
    { name: name, slug: slug, description: unescape(desc.to_s), parameters: parse_parameters(src) }
  end

  # === TypeBox -> JSON Schema (parser recursivo) ===========================
  # O `const parameters = Type.Object({...});` é a raiz. Type.Object já É JSON
  # Schema; só precisamos reconstruí-lo como Hash aninhado dentro do subset seguro
  # da ToolDefinition (object/array/string/number/integer/boolean + description/
  # min*/max*/additionalProperties). Type.Optional só afeta o `required` do pai.

  def empty_schema = { "type" => "object", "properties" => {}, "required" => [] }

  def parse_parameters(src)
    at = src.match(/const\s+parameters\s*=\s*/)
    return empty_schema if at.nil?

    expr = extract_type_expr(src, at.end(0))
    return empty_schema if expr.nil?

    parse_type(expr)
  end

  # A partir de `from`, isola a expressão `Type.X( ... )` inteira (parênteses
  # balanceados) — a raiz do schema.
  def extract_type_expr(src, from)
    idx = src.index("Type.", from)
    return nil if idx.nil?

    open = src.index("(", idx)
    close = open && match_delim(src, open)
    return nil if open.nil? || close.nil?

    src[idx..close]
  end

  # Uma expressão `Type.Kind(<args>)` -> Hash JSON Schema. Kind fora do subset
  # degrada p/ string com aviso (R1).
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
    when "Optional" then parse_type(args)           # desembrulha; required é do pai
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
  # Um campo cujo valor é Type.Optional(...) NÃO entra em `required`.
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

  # Type desconhecido (fora do subset): degrada p/ string, avisando (R1). Nenhum
  # dos 44 tools atuais cai aqui — é só rede de segurança p/ o futuro.
  def degrade(expr, kind = nil)
    label = kind || expr[/\AType\.(\w+)/, 1] || expr[0, 20]
    warn "  [aviso] TypeBox '#{label}' fora do subset seguro -> degradado p/ string"
    { "type" => "string" }
  end

  # Extrai description/min*/max*/additionalProperties de um literal `{ ... }` de
  # opções (ou string vazia / nil). Só chaves do subset; o resto é ignorado.
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

  # === helpers de parsing (balanceamento/split) ============================

  # Índice do delimitador de fechamento que casa com o aberto em `open_idx`,
  # ignorando delimitadores dentro de strings JS.
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

  # Quebra `s` nas vírgulas de TOPO (fora de (), {}, [] e strings).
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

  # Itera os pares `chave: valor` de TOPO de um literal `{ ... }` de objeto.
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

  # Posição do primeiro `:` de TOPO (fora de delimitadores/strings) — separa
  # chave do valor num campo de objeto.
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

  # === montagem da tool no manifesto =======================================

  def tool_entry(tool)
    {
      "name" => tool[:name],
      "group" => group_for(tool[:name]),
      "endpoint" => tool[:slug], # slug do callAgentTool — nunca inferido do name (R6)
      "description" => tool[:description],
      "parameters" => tool[:parameters],
      "body" => body_template(tool[:parameters]),
      "side_effect" => side_effect_for(tool[:name])
    }
  end

  # Grupo por convenção de nome (prioridade: natura/cacau > sufixo > shared/core >
  # default). Espelha a derivação em runtime do OpenClaw, agora como DADO.
  def group_for(name)
    return "natura" if name.start_with?("natura_")
    return "cacau" if name.start_with?("cacau_")
    return "b2b" if name.end_with?("_b2b")
    return "groceries" if name.end_with?("_groceries") || GROCERIES_SHARED.include?(name)
    return "core" if CORE_TOOLS.include?(name)

    "default"
  end

  # reads (search_/get_/list_) não são side-effect (reexecutam no resume);
  # o resto muta (mesma heurística do openclaw_to_pack).
  def side_effect_for(name) = name !~ /\A(search|get|list)_/

  # Template do corpo: reencaminha CADA param de TOPO. Objetos/arrays vão inteiros
  # (`{{k}}` — o DataDefinedTool serializa o valor em JSON); string vai entre aspas.
  # É o que reproduz o `callAgentTool("<slug>", params)` do plugin (params completo).
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
# Guard: só roda quando executado direto (o spec dá `require` e chama as funções).
if $PROGRAM_NAME == __FILE__
  plugin_dir = ARGV[0] || ENV["OPENCLAW_PLUGIN_DIR"] || OpenclawToManifest::DEFAULT_PLUGIN_DIR
  out_file = ARGV[1] || "manifesto.json"

  abort("plugin sem index.ts em #{plugin_dir}") unless File.exist?(File.join(plugin_dir, "index.ts"))

  manifest = OpenclawToManifest.build_manifest(plugin_dir)
  File.write(out_file, JSON.pretty_generate(manifest) + "\n")

  by_group = manifest["tools"].group_by { |t| t["group"] }.transform_values(&:size).sort.to_h
  puts "plugin:    #{plugin_dir}"
  puts "manifesto: #{out_file} (#{manifest['tools'].size} tools)"
  puts "grupos:    #{by_group.map { |g, n| "#{g}=#{n}" }.join(', ')}"
end

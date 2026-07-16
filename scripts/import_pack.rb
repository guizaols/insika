# frozen_string_literal: true

# Provisiona um PACK (pasta docs/prompt-base/06: agent.config.json + *.md +
# skills/*/SKILL.md + tools/*.json) no harness que ESTÁ RODANDO, via
# POST /v1/agents. Roda como CLIENTE (não sobe o deployment; não precisa de
# DEEPSEEK_API_KEY) — o SERVER faz o import, então o overlay de tools e o
# catálogo de skills recarregam NO processo do server (valem no próximo turno).
#
# Uso:
#   HARNESS_URL=http://localhost:9292 \
#   OPENCLAW_GATEWAY_TOKEN=local-demo \
#   BIA_INTERNAL_API_TOKEN=<token interno do consumer-app> \
#   bundle exec ruby scripts/import_pack.rb /caminho/do/pack
#
# O BIA_INTERNAL_API_TOKEN substitui o placeholder __BIA_INTERNAL_API_TOKEN__ dos
# secret_headers das tools em memória — o segredo NÃO fica nos .json do pack.

require_relative "../lib/harness"
require "net/http"
require "json"
require "uri"

dir = ARGV[0] or abort("uso: import_pack.rb <dir-do-pack>")
base   = ENV.fetch("HARNESS_URL", "http://localhost:9292")
token  = ENV["OPENCLAW_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"] || "local-demo"
secret = ENV["BIA_INTERNAL_API_TOKEN"]

pack = Harness::Pack.from_dir(dir)

# Injeta o token interno real nos secret_headers (fica fora do disco).
placeholder = "__BIA_INTERNAL_API_TOKEN__"
tools = pack.tools.map do |t|
  h = (t["request"] || t[:request] || {})
  headers = (h["headers"] || h[:headers] || {})
  if secret && headers.values.any? { |v| v.to_s.include?(placeholder) }
    headers = headers.transform_values { |v| v.to_s.gsub(placeholder, secret) }
    h = h.merge("headers" => headers)
    t = t.merge("request" => h)
  end
  t
end
warn "aviso: BIA_INTERNAL_API_TOKEN não setado — placeholder fica no header (tool dará 401)" if secret.nil?

body = { config: pack.config, files: pack.files, skills: pack.skills, tools: tools }
uri = URI.join(base, "/v1/agents")
req = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json")
req.body = JSON.generate(body)

res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
puts "POST #{uri} -> #{res.code}"
puts res.body
abort("falhou") unless res.code.to_i.between?(200, 299)

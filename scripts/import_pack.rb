# frozen_string_literal: true

# Provisions a PACK (docs/prompt-base/06 folder: agent.config.json + *.md +
# skills/*/SKILL.md + tools/*.json) into the insika that IS RUNNING, via
# POST /v1/agents. Runs as a CLIENT (does not boot the deployment; does not need
# DEEPSEEK_API_KEY) — the SERVER does the import, so the tool overlay and the
# skill catalog reload IN the server process (effective on the next turn).
#
# Usage:
#   INSIKA_URL=http://localhost:9292 \
#   OPENCLAW_GATEWAY_TOKEN=local-demo \
#   BIA_INTERNAL_API_TOKEN=<the consumer's internal token> \
#   bundle exec ruby scripts/import_pack.rb /path/to/pack
#
# BIA_INTERNAL_API_TOKEN replaces the __BIA_INTERNAL_API_TOKEN__ placeholder in the
# tools' secret_headers in memory — the secret does NOT live in the pack's .json.

require_relative "../lib/insika"
require "net/http"
require "json"
require "uri"

dir = ARGV[0] or abort("usage: import_pack.rb <pack-dir>")
base   = ENV["INSIKA_URL"] || ENV["HARNESS_URL"] || "http://localhost:9292"
token  = ENV["OPENCLAW_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"] || "local-demo"
secret = ENV["BIA_INTERNAL_API_TOKEN"]

pack = Insika::Pack.from_dir(dir)

# Inject the real internal token into the secret_headers (stays off disk).
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
warn "warning: BIA_INTERNAL_API_TOKEN not set — placeholder stays in the header (tool will 401)" if secret.nil?

body = { config: pack.config, files: pack.files, skills: pack.skills, tools: tools }
uri = URI.join(base, "/v1/agents")
req = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json")
req.body = JSON.generate(body)

res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
puts "POST #{uri} -> #{res.code}"
puts res.body
abort("failed") unless res.code.to_i.between?(200, 299)

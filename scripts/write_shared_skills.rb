# frozen_string_literal: true

# Writes the skills the achei-b2b packs cite BY NAME (`config.skills` of the
# HttpEnginePackConfig: GUARDRAIL_SKILLS + GROCERY_SKILLS) into the SHARED scope
# of the insika that IS RUNNING, via POST /v1/commands/write_skill without
# `agent`. One record per skill for every agent — what a pack's own skills/
# dirs never are (the PackImporter writes those into the agent's scope).
#
# Source: the openclaw checkout — `skills-shared/<name>/SKILL.md` plus the
# keyword lists of its `grocery-skills-injector` hook. Two adaptations, because
# that hook did work the insika does differently:
#
#   triggers — the hook injected each grocery roteiro when the customer's
#     message hit its keyword list (DeepSeek does not call `read` on its own).
#     The insika does the same from a `triggers:` frontmatter line
#     (Context::Providers::SkillTrigger), so the lists move into the skills.
#     Match is whole-word here, substring there.
#   {{LOJA}} — the hook replaced it with the store name; the insika has no
#     placeholder, and the store name already reaches the prompt by IDENTITY.md.
#
# write_skill is an upsert and reloads the catalog, so a re-run converges and
# agents whose allowlist already names a skill see it on the next turn.
#
# Dry-run by default; `apply` as the 2nd argument writes.
#
#   INSIKA_URL=https://<insika> INSIKA_GATEWAY_TOKEN=<token> \
#   ruby scripts/write_shared_skills.rb ~/projetos/tedi/openclaw/openclaw [apply]

# Only the parse the catalog runs on reload: the client needs no gem of the server.
require_relative "../lib/insika/coercion"
require_relative "../lib/insika/frontmatter"
require_relative "../lib/insika/skill_catalog"
require "net/http"
require "json"
require "uri"

SKILLS = %w[
  conduct-guardrails security-guardrails
  form-of-address grocery-core grocery-discovery grocery-offers
  grocery-category-nav grocery-substitution grocery-budget
].freeze

# skill => the hook's keyword constant.
TRIGGER_LISTS = {
  "grocery-discovery" => "DISCOVERY_KEYWORDS",
  "grocery-offers" => "OFFERS_KEYWORDS",
  "grocery-category-nav" => "CATEGORY_NAV_KEYWORDS",
  "grocery-substitution" => "SUBSTITUTION_KEYWORDS",
  "grocery-budget" => "BUDGET_KEYWORDS"
}.freeze

HOOK = "extensions/acheib2b-tools-dev/hooks/grocery-discovery-injector.ts"
LOJA = { " `{{LOJA}}` é substituído pelo nome real da loja em runtime." => "",
         "de {{LOJA}}" => "da loja", "em {{LOJA}}" => "na loja" }.freeze

root = ARGV[0] or abort("usage: write_shared_skills.rb <openclaw-dir> [apply]")
apply = ARGV[1] == "apply"
base = ENV["INSIKA_URL"] or abort("INSIKA_URL not set")
token = ENV["INSIKA_GATEWAY_TOKEN"] or abort("INSIKA_GATEWAY_TOKEN not set")

hook = File.read(File.join(root, HOOK), encoding: "UTF-8")
keywords = lambda do |const|
  block = hook[/const #{const} = \[(.*?)\];/m, 1] or abort("#{const} not found in #{HOOK}")
  block.lines.reject { |l| l.strip.start_with?("//") }.join.scan(/"([^"]+)"/).flatten.uniq
end

# Comma-separated, not a YAML list: the frontmatter falls back to a line-by-line
# parse when the description breaks strict YAML, and a `[...]` would then arrive
# as one string with the brackets and quotes in it.
add_triggers = lambda do |content, list|
  abort("keyword with a comma: #{list.grep(/,/)}") if list.any? { |k| k.include?(",") }
  content.sub(/\A(---\s*\n.*?)(\n---\s*\n)/m) { "#{$1}\ntriggers: #{list.join(', ')}#{$2}" }
end

# Read, adapt and check all nine BEFORE writing any, so a bad source never
# leaves the set half-written.
skills = SKILLS.to_h do |name|
  path = File.join(root, "skills-shared", name, "SKILL.md")
  abort("missing #{path}") unless File.file?(path)

  content = File.read(path, encoding: "UTF-8")
  content = LOJA.reduce(content) { |text, (from, to)| text.gsub(from, to) }
  abort("#{name}: {{LOJA}} left without a replacement") if content.include?("{{LOJA}}")

  expected = TRIGGER_LISTS[name] ? keywords.call(TRIGGER_LISTS[name]) : []
  content = add_triggers.call(content, expected) if expected.any?

  # The same parse the insika runs on reload: what it reads back is what lands.
  skill = Insika::SkillCatalog.allocate.send(:parse_content, content, path: path)
  abort("#{name}: frontmatter does not parse") unless skill&.name == name
  abort("#{name}: triggers #{skill.triggers.size} != #{expected.size}") unless skill.triggers == expected

  [name, content]
end

uri = URI.join(base, "/v1/commands/write_skill")
skills.each do |name, content|
  triggers = content[/^triggers: (.*)$/, 1].to_s.split(", ").size
  unless apply
    puts "dry-run  #{name} (#{content.bytesize} bytes, #{triggers} triggers)"
    next
  end

  req = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json")
  req.body = JSON.generate(name: name, content: content)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
  puts "#{res.code}  #{name}  #{res.body}"
  abort("failed on #{name}") unless res.code.to_i.between?(200, 299)
end
puts "\ndry-run: nothing written. Pass `apply` as the 2nd argument." unless apply

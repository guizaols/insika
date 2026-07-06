# frozen_string_literal: true

require "ruby_llm"
require_relative "../lib/agent_runtime"
require_relative "../tools/lookup_product"

RubyLLM.configure do |c|
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  c.request_timeout = 120
  c.max_retries = 3
end

ROOT = File.expand_path("..", __dir__)

# 1. Registro de tools. Defaults do sistema (required) registrados direto.
REGISTRY = AgentRuntime::ToolRegistry.new
REGISTRY.register("lookup_product", LookupProduct, optional: false)

# 2. Plugins: manifesto -> registra tools + devolve dirs de skills.
#    bundled precisa ser habilitado explicitamente (enabled).
PLUGIN_SKILL_DIRS = AgentRuntime::PluginLoader.new(
  [File.join(ROOT, "plugins")],
  registry: REGISTRY,
  enabled: %w[weather]
).load_all

# 3. Catálogo de skills. Workspace primeiro (maior precedência), depois os
#    dirs de skills dos plugins (menor precedência).
CATALOG = AgentRuntime::SkillCatalog.new(
  [File.join(ROOT, "skills"), *PLUGIN_SKILL_DIRS]
)

SYSTEM_PROMPT = AgentRuntime::SystemPrompt.new(
  files: [File.join(ROOT, "SOUL.md")]
)

# 4. Perfis de agente (data-driven). Cada um com sua política de tool/skill.
Profile = AgentRuntime::AgentProfile
MODEL = ENV.fetch("AGENT_MODEL", "claude-sonnet-4-5")

PROFILES = {
  # Vendas: todas as skills; lookup_product (default) + get_weather (opt-in).
  "sales" => Profile.build(
    id: "sales", model: MODEL, prompt_files: [File.join(ROOT, "SOUL.md")],
    tools_allow: %w[lookup_product get_weather], skills: nil
  ),
  # Travado: nenhuma skill, so a tool default.
  "locked" => Profile.build(
    id: "locked", model: MODEL, prompt_files: [File.join(ROOT, "SOUL.md")],
    tools_allow: %w[lookup_product], skills: []
  )
}

RUNNER = AgentRuntime::Runner.new(
  registry: REGISTRY,
  catalog: CATALOG,
  system_prompt: SYSTEM_PROMPT,
  profiles: PROFILES
)

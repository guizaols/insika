# frozen_string_literal: true

# Builder compartilhado do smoke E2E (task 26 §7): wiring PRÓPRIO com backend
# Stores::SQLite (ENV SMOKE_DB — durabilidade real é o que o kill -9 testa) + um
# perfil "smoke" apontando para o modelo fake (o shim de ruby_llm entra via
# RUBYOPT=-I). Sem plugins externos. Expõe SMOKE_APP já passado pelo Boot (que
# roda o Recovery ANTES de qualquer request). Consumido por config.ru (rackup)
# e por serve.rb (servidor single-process do teste).
root = File.expand_path("../../..", __dir__)
require File.join(root, "lib", "harness")
require File.join(root, "server", "app")
require File.join(root, "server", "boot")

backend          = Harness::Stores::SQLite.new(path: ENV.fetch("SMOKE_DB"))
session_store    = Harness::SessionStore.new(store: backend)
task_store       = Harness::TaskStore.new(store: backend)
checkpoint_store = Harness::CheckpointStore.new(store: backend)
event_stream     = Harness::EventStream.new

tool_registry     = Harness::ToolRegistry.new
workflow_registry = Harness::WorkflowRegistry.new
policy_registry   = Harness::PolicyRegistry.new
skill_catalog     = Harness::SkillCatalog.new([])
prompt_catalog    = Harness::PromptCatalog.new([])
hooks             = Harness::Hooks.new
middleware        = Harness::MiddlewareStack.new([])

providers = [
  Harness::Context::Providers::Request.new,
  Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: prompt_catalog),
  Harness::Context::Providers::Skill.new(catalog: skill_catalog),
  Harness::Context::Providers::Session.new(session_store: session_store)
]
context_builder = Harness::ContextBuilder.new(providers: providers, event_stream: event_stream, hooks: hooks)
policy_engine   = Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream)

# Perfil sem policies/skills/tools: o turno é puro chat (o FakeChat ignora tools).
profiles = {
  "smoke" => Harness::AgentProfile.build(id: "smoke", model: "fake", policies: [], skills: [])
}

executor = Harness::Executor.new(
  context_builder: context_builder, policy_engine: policy_engine,
  middleware: middleware, hooks: hooks, tool_registry: tool_registry,
  skill_catalog: skill_catalog, profiles: profiles, session_store: session_store,
  task_store: task_store, checkpoint_store: checkpoint_store,
  event_stream: event_stream, workflow_registry: workflow_registry
)

bus = Harness::CommandBus.new(event_stream: event_stream)
bus.register(:create_session,
             Harness::Commands::CreateSession.new(session_store: session_store, event_stream: event_stream))
bus.register(:send_message,
             Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                 task_store: task_store, executor: executor))
bus.register(:resume_task,
             Harness::Commands::ResumeTask.new(profiles: profiles, task_store: task_store,
                                               checkpoint_store: checkpoint_store, executor: executor))
bus.register(:cancel_task,
             Harness::Commands::CancelTask.new(task_store: task_store, executor: executor))

app = Harness::Server::App.new(
  command_bus: bus, event_stream: event_stream, session_store: session_store,
  task_store: task_store, checkpoint_store: checkpoint_store,
  catalogs: { skills: skill_catalog, prompts: prompt_catalog },
  registries: { tools: tool_registry, workflows: workflow_registry, policies: policy_registry },
  config: { admin_token: nil, allowed_origins: [] }
)

recovery = Harness::Recovery.new(task_store: task_store, checkpoint_store: checkpoint_store, command_bus: bus)

# Instrumentação do teste: grava um marker ao FIM do Recovery.run. Como o Boot
# roda o recovery antes de liberar o app (e o serve.rb só serve depois), a
# primeira resposta HTTP prova que o recovery já terminou (doc 07 §7).
if (recovery_marker = ENV["SMOKE_RECOVERY_DONE"])
  real_recovery = recovery
  recovery = Object.new
  recovery.define_singleton_method(:run) do
    result = real_recovery.run
    File.write(recovery_marker, "done")
    result
  end
end

# Wiring mínimo com os passos nomeados que o Boot orquestra.
wiring = Object.new
wiring.define_singleton_method(:load_plugins) { nil }
wiring.define_singleton_method(:build_stores) { nil }
wiring.define_singleton_method(:recovery) { recovery }
wiring.define_singleton_method(:app) { app }

# O Boot roda plugins → stores → recovery ANTES de liberar o app (doc 07 §4).
SMOKE_APP = Harness::Server::Boot.new(wiring, logger: $stderr).call

# frozen_string_literal: true

# Shared builder for the E2E smoke (task 26 §7): OWN wiring with a Stores::SQLite
# backend (ENV SMOKE_DB — real durability is what the kill -9 tests) + a "smoke"
# profile pointing at the fake model (the ruby_llm shim comes in via RUBYOPT=-I).
# No external plugins. Exposes SMOKE_APP already run through Boot (which runs
# Recovery BEFORE any request). Consumed by config.ru (rackup) and by serve.rb (the
# test's single-process server).
root = File.expand_path("../../..", __dir__)
require File.join(root, "lib", "insika")
require File.join(root, "server", "app")
require File.join(root, "server", "boot")

backend              = Insika::Stores::SQLite.new(path: ENV.fetch("SMOKE_DB"))
session_store        = Insika::SessionStore.new(store: backend)
task_store           = Insika::TaskStore.new(store: backend)
checkpoint_store     = Insika::CheckpointStore.new(store: backend)
pending_action_store = Insika::PendingActionStore.new(store: backend)
event_stream         = Insika::EventStream.new

tool_registry     = Insika::ToolRegistry.new
workflow_registry = Insika::WorkflowRegistry.new
policy_registry   = Insika::PolicyRegistry.new
policy_registry.register(:tool_allowlist, Insika::Policy::Builtin::ToolAllowlist)
policy_registry.register(:approval_required, Insika::Policy::Builtin::ApprovalRequired)

# Tool that requires approval (P2-02) — used by slice A's smoke. The block factory
# returns an INSTANCE (the Executor does factory.call -> instance).
class SmokeChargeTool
  def name = "charge"
  def call(_args) = "charged"
end
tool_registry.register("charge") { SmokeChargeTool.new }
skill_catalog     = Insika::SkillCatalog.new([])
prompt_catalog    = Insika::PromptCatalog.new([])
hooks             = Insika::Hooks.new
middleware        = Insika::MiddlewareStack.new([])

providers = [
  Insika::Context::Providers::Request.new,
  Insika::Context::Providers::Prompt.new(base: "", files: [], catalog: prompt_catalog),
  Insika::Context::Providers::Skill.new(catalog: skill_catalog),
  Insika::Context::Providers::Session.new(session_store: session_store)
]
context_builder = Insika::ContextBuilder.new(providers: providers, event_stream: event_stream, hooks: hooks)
policy_engine   = Insika::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream)

# "smoke": pure chat. "approver": requires approval of the `charge` tool (P2-02).
profiles = {
  "smoke" => Insika::AgentProfile.build(id: "smoke", model: "fake", policies: [], skills: []),
  "approver" => Insika::AgentProfile.build(
    id: "approver", model: "fake", skills: [], tools_allow: ["charge"],
    policies: %i[tool_allowlist approval_required], approvals_required: ["charge"]
  )
}

executor = Insika::Executor.new(
  context_builder: context_builder, policy_engine: policy_engine,
  middleware: middleware, hooks: hooks, tool_registry: tool_registry,
  skill_catalog: skill_catalog, profiles: profiles, session_store: session_store,
  task_store: task_store, checkpoint_store: checkpoint_store,
  event_stream: event_stream, workflow_registry: workflow_registry,
  pending_action_store: pending_action_store
)
# Exposed so serve.rb can inject the turn supervisor (L4) into the serving reactor.
SMOKE_EXECUTOR = executor

bus = Insika::CommandBus.new
bus.register(:create_session,
             Insika::Commands::CreateSession.new(session_store: session_store, event_stream: event_stream))
bus.register(:send_message,
             Insika::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                 task_store: task_store, executor: executor))
bus.register(:resume_task,
             Insika::Commands::ResumeTask.new(profiles: profiles, task_store: task_store,
                                               checkpoint_store: checkpoint_store, executor: executor))
bus.register(:cancel_task,
             Insika::Commands::CancelTask.new(task_store: task_store, executor: executor))
bus.register(:pause_task,
             Insika::Commands::PauseTask.new(task_store: task_store, executor: executor))
bus.register(:approve_action,
             Insika::Commands::ApproveAction.new(pending_action_store: pending_action_store,
                                                  executor: executor, event_stream: event_stream))

app = Insika::Server::App.new(
  command_bus: bus, event_stream: event_stream, session_store: session_store,
  task_store: task_store, pending_action_store: pending_action_store,
  # The /v1 surface is fail-closed: no token configured -> 503 for everything. The
  # smoke drives it over HTTP, so it configures one (the spec sends this Bearer).
  config: { gateway_token: ENV.fetch("SMOKE_TOKEN", "smoke-token") }
)

recovery = Insika::Recovery.new(task_store: task_store, checkpoint_store: checkpoint_store, command_bus: bus)

# Test instrumentation: writes a marker at the END of Recovery.run. Since the Boot
# runs recovery before releasing the app (and serve.rb only serves afterwards), the
# first HTTP response proves recovery already finished (doc 07 §7).
if (recovery_marker = ENV["SMOKE_RECOVERY_DONE"])
  real_recovery = recovery
  recovery = Object.new
  recovery.define_singleton_method(:run) do
    result = real_recovery.run
    File.write(recovery_marker, "done")
    result
  end
end

# Minimal wiring with the named steps the Boot orchestrates.
wiring = Object.new
wiring.define_singleton_method(:load_plugins) { nil }
wiring.define_singleton_method(:build_stores) { nil }
wiring.define_singleton_method(:recovery) { recovery }
wiring.define_singleton_method(:app) { app }

# The Boot runs plugins → stores → recovery BEFORE releasing the app (doc 07 §4).
SMOKE_APP = Insika::Server::Boot.new(wiring, logger: $stderr).call

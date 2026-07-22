# frozen_string_literal: true

# Deployment wiring for the "harness-code" prototype: a Claude-Code-style code
# agent built ON TOP of the harness engine, consuming it as a library. It builds
# the SAME object graph as config/wiring.rb (stores, registries, policy engine,
# executor, command bus, HTTP app) but with:
#
#   * the FS/shell toolset from plugins/harness-code, loaded through the real
#     Plugin::Loader (RFC-0003 autodiscovery);
#   * one agent profile ("harness-code") that allows those tools and lists the
#     write/shell ones in `approvals_required` — so the engine's existing
#     human-approval gate protects them;
#   * a gateway token so POST /v1/responses (the OpenAI Responses adapter the CLI
#     speaks) is authenticated.
#
# No core files are modified. Requiring this file gives HarnessCodeApp::Wiring.

require "yaml"
require_relative "../../lib/harness"
require "ruby_llm"
require_relative "../../server/app"

module HarnessCodeApp
  REPO_ROOT = File.expand_path("../..", __dir__)

  # The sandbox root every FS/shell tool is confined to. Resolved once and
  # written back to ENV so the plugin (which reads HARNESS_CODE_ROOT at register
  # time) sees the exact same absolute path.
  WORKSPACE_ROOT = File.expand_path(
    ENV["HARNESS_CODE_ROOT"].to_s.empty? ? Dir.pwd : ENV["HARNESS_CODE_ROOT"]
  )
  ENV["HARNESS_CODE_ROOT"] = WORKSPACE_ROOT

  # Declarative sandbox policy (item 35, config-over-code): `local` (in-process,
  # default) or `docker` (isolated container, `HARNESS_CODE_SANDBOX=docker`). The
  # SAME hash is stored on the agent profile below AND read by the plugin to build
  # the tools' Sandbox, so profile and runtime never drift. Docker knobs
  # (image/network/…) default conservatively inside Harness::Sandbox::Docker and
  # are overridable via HARNESS_CODE_SANDBOX_* env.
  SANDBOX_CONFIG = {
    "provider"   => (ENV["HARNESS_CODE_SANDBOX"].to_s.empty? ? "local" : ENV["HARNESS_CODE_SANDBOX"]),
    "root"       => WORKSPACE_ROOT,
    "image"      => ENV["HARNESS_CODE_SANDBOX_IMAGE"],
    "network"    => ENV["HARNESS_CODE_SANDBOX_NETWORK"]
  }.reject { |_k, v| v.to_s.empty? }.freeze

  MODEL         = ENV.fetch("HARNESS_CODE_MODEL", "deepseek-chat")
  PROVIDER      = ENV.fetch("HARNESS_CODE_PROVIDER", "deepseek").to_sym
  GATEWAY_TOKEN = ENV.fetch("HARNESS_CODE_TOKEN", "local-code")

  # Provider-agnostic LLM config: wire up whatever API keys are present. Like the
  # demo deployment, a missing key does NOT crash boot — the engine comes up and
  # turns fail with a clear provider error until a key exists.
  RubyLLM.configure do |c|
    if ENV["DEEPSEEK_API_KEY"]
      c.deepseek_api_key  = ENV["DEEPSEEK_API_KEY"]
      c.deepseek_api_base = "https://api.deepseek.com/v1"
    end
    c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] if ENV["ANTHROPIC_API_KEY"]
    c.openai_api_key    = ENV["OPENAI_API_KEY"] if ENV["OPENAI_API_KEY"]
    c.request_timeout = 120
    c.max_retries = 2
  rescue NoMethodError
    # older/newer ruby_llm without one of the optional setters — ignore.
  end

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are harness-code, a terminal coding assistant operating inside a single
    workspace directory. You help the user read, search, and edit code and run
    shell commands, all confined to that workspace.

    Tools available to you:
      - read_file(path): read a file's contents.
      - list_dir(path): list a directory (defaults to the workspace root).
      - grep(pattern, path): search files for a regular expression.
      - write_file(path, content): create or overwrite a file.
      - edit_file(path, old_string, new_string): replace an exact, unique string.
      - bash(command): run a shell command from the workspace root.

    Rules:
      - All paths are RELATIVE to the workspace root. You cannot access anything
        outside it; attempts return a sandbox error.
      - Before editing a file, read it so your old_string matches exactly and is
        unique.
      - write_file, edit_file and bash require the human to approve each call.
        Explain briefly what you are about to do so the approval is easy to judge.
      - Keep responses concise. Prefer making the change over describing it.
  PROMPT

  module Wiring
    BACKEND =
      if (db = ENV["HARNESS_DB"]) && !db.empty?
        Harness::Stores::SQLite.new(path: db)
      else
        Harness::Stores::Memory.new
      end

    SESSION_STORE        = Harness::SessionStore.new(store: BACKEND)
    TASK_STORE           = Harness::TaskStore.new(store: BACKEND)
    CHECKPOINT_STORE     = Harness::CheckpointStore.new(store: BACKEND)
    PENDING_ACTION_STORE = Harness::PendingActionStore.new(store: BACKEND)
    MEMORY_STORE         = Harness::MemoryStore.new(store: BACKEND)
    EVENT_STREAM         = Harness::EventStream.new

    REGISTRY          = Harness::ToolRegistry.new
    WORKFLOW_REGISTRY = Harness::WorkflowRegistry.new
    POLICY_REGISTRY   = Harness::PolicyRegistry.new
    POLICY_REGISTRY.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
    POLICY_REGISTRY.register(:skill_allowlist, Harness::Policy::Builtin::SkillAllowlist)
    POLICY_REGISTRY.register(:approval_required, Harness::Policy::Builtin::ApprovalRequired)

    HOOKS               = Harness::Hooks.new
    MIDDLEWARE          = Harness::MiddlewareStack.new([])
    CAPABILITY_REGISTRY = Harness::CapabilityRegistry.new

    # Load the FS/shell toolset via the real plugin Loader (autodiscovery).
    PLUGIN_DIR = File.join(HarnessCodeApp::REPO_ROOT, "plugins", "harness-code")
    Harness::Plugin::Loader.new(
      roots: [PLUGIN_DIR],
      registries: {
        tools: REGISTRY, workflows: WORKFLOW_REGISTRY, policies: POLICY_REGISTRY,
        capabilities: CAPABILITY_REGISTRY, hooks: HOOKS,
        middleware: MIDDLEWARE, context_providers: []
      },
      enabled: ["harness-code"], event_stream: EVENT_STREAM
    ).load_all

    # Defense-in-depth (example-local, no core change): derive the approval set
    # straight from the plugin manifest so EVERY tool flagged `side_effect: true`
    # is approval-gated automatically. Hard-coding the list by hand risks drift —
    # add a side-effecting tool and forget to list it, and it would run ungated.
    # Reading it from the manifest (the single source of truth) makes that class
    # of mistake impossible. See README §"Security boundary".
    SIDE_EFFECT_TOOLS = YAML.load_file(File.join(PLUGIN_DIR, "harness.plugin.yml"))
                            .fetch("tool_metadata", {})
                            .select { |_name, meta| meta["side_effect"] }
                            .keys.freeze

    TOOL_CATALOG   = Harness::ToolCatalog.new(tool_registry: REGISTRY)
    CATALOG        = Harness::SkillCatalog.new([])
    PROMPT_CATALOG = Harness::PromptCatalog.new([])

    CONTEXT_PROVIDERS = [
      Harness::Context::Providers::Request.new,
      Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
      Harness::Context::Providers::Skill.new(catalog: CATALOG),
      Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
      Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
    ].freeze
    CONTEXT_BUILDER = Harness::ContextBuilder.new(
      providers: CONTEXT_PROVIDERS, event_stream: EVENT_STREAM, hooks: HOOKS
    )
    POLICY_ENGINE = Harness::Policy::Engine.new(
      policy_registry: POLICY_REGISTRY, event_stream: EVENT_STREAM
    )

    # The code agent. Read tools are ungated; write/shell tools are listed in
    # approvals_required, so the ApprovalRequired policy marks them and the
    # ToolEnvelope suspends the turn for human approval before they execute.
    PROFILE = Harness::AgentProfile.build(
      id: "harness-code", model: HarnessCodeApp::MODEL, provider: HarnessCodeApp::PROVIDER,
      base_prompt: HarnessCodeApp::SYSTEM_PROMPT,
      tools_allow: %w[read_file list_dir grep write_file edit_file bash],
      policies: %i[tool_allowlist approval_required],
      approvals_required: SIDE_EFFECT_TOOLS,
      # Config-over-code: the sandbox provider/policy is DATA on the profile,
      # consumed by Harness::Sandbox.build. The plugin reads the same config from
      # ENV, so the tools' runtime sandbox matches this declaration.
      sandbox: HarnessCodeApp::SANDBOX_CONFIG,
      limits: {
        tool_timeout: Integer(ENV.fetch("HARNESS_CODE_TOOL_TIMEOUT", "120")),
        turn_timeout: Integer(ENV.fetch("HARNESS_CODE_TURN_TIMEOUT", "600")),
        approval_timeout: Integer(ENV.fetch("HARNESS_CODE_APPROVAL_TIMEOUT", "3600")),
        max_tool_calls: 100
      }
    )
    PROFILES = { "harness-code" => PROFILE }.freeze

    EXECUTOR = Harness::Executor.new(
      context_builder: CONTEXT_BUILDER, policy_engine: POLICY_ENGINE,
      middleware: MIDDLEWARE, hooks: HOOKS,
      tool_registry: REGISTRY, skill_catalog: CATALOG, profiles: PROFILES,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      checkpoint_store: CHECKPOINT_STORE, event_stream: EVENT_STREAM,
      workflow_registry: WORKFLOW_REGISTRY, pending_action_store: PENDING_ACTION_STORE,
      capability_registry: CAPABILITY_REGISTRY, tool_catalog: TOOL_CATALOG,
      memory_store: MEMORY_STORE
    )

    BUS = Harness::CommandBus.new
    BUS.register(:create_session,
                 Harness::Commands::CreateSession.new(session_store: SESSION_STORE,
                                                      event_stream: EVENT_STREAM))
    BUS.register(:send_message,
                 Harness::Commands::SendMessage.new(profiles: PROFILES, session_store: SESSION_STORE,
                                                    task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:cancel_task,
                 Harness::Commands::CancelTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:pause_task,
                 Harness::Commands::PauseTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    # Human-in-the-loop approvals: the CLI posts this command to resolve a
    # pending FS/shell action and wake the suspended turn.
    BUS.register(:approve_action,
                 Harness::Commands::ApproveAction.new(pending_action_store: PENDING_ACTION_STORE,
                                                      executor: EXECUTOR, event_stream: EVENT_STREAM))

    APP = Harness::Server::App.new(
      command_bus: BUS, event_stream: EVENT_STREAM,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      checkpoint_store: CHECKPOINT_STORE, pending_action_store: PENDING_ACTION_STORE,
      catalogs: { skills: CATALOG, prompts: PROMPT_CATALOG },
      registries: { tools: REGISTRY, workflows: WORKFLOW_REGISTRY, policies: POLICY_REGISTRY },
      config: { gateway_token: HarnessCodeApp::GATEWAY_TOKEN,
                admin_token: HarnessCodeApp::GATEWAY_TOKEN, allowed_origins: [] }
    )

    def self.durable? = BACKEND.is_a?(Harness::Stores::SQLite)
  end
end

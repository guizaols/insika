# frozen_string_literal: true

require "ruby_llm"
require_relative "workflow_adapter"

module Insika
  module DSL
    # The live graph behind a Definition: it assembles the SAME authoring graph a
    # concrete deployment does (Insika::Wiring::Graph + the runtime-authoring
    # command surface), configures RubyLLM, and imports the definition's pack via
    # the standard PackImporter. From there the agent is indistinguishable from one
    # provisioned by any other pack — chat and serve just drive the normal path.
    #
    # Built lazily by Definition#runtime, so `require "insika"` never pays for
    # ruby_llm or the HTTP server.
    class Runtime
      # graph: the assembled Wiring::Graph::Result; pack: the PRIMARY imported
      # Pack; packs: every imported Pack (one per agent — a System has N, a
      # Definition has one). All read by the server boot and the specs.
      attr_reader :graph, :pack, :packs

      # `definition` is a Definition (one agent) or a System (N agents). Both
      # answer #pack/#id; a System also answers #packs. Duck-typed on purpose:
      # the runtime does not care how many agents it hosts, only that each one
      # arrives as an ordinary Pack.
      #
      # `backend`: the store this graph owns. nil = the historic
      # path, `INSIKA_DB` or memory — ENV is a default, never a requirement (the
      # embed contract). An injected backend wins and is never widened
      # back to the environment.
      def initialize(definition, backend: nil)
        @definition = definition
        @injected_backend = backend
        @packs = (definition.respond_to?(:packs) ? Array(definition.packs) : [definition.pack]).freeze
        @pack = @packs.first
        # the graph's OWN RubyLLM config, built before the graph so
        # every collaborator that talks to a provider is handed it at wiring time
        # rather than reading a process-wide singleton at call time.
        @llm = build_llm_context
        @graph = build_graph
        # the dispatch+drain seam `#chat`/`#run_workflow` delegate to —
        # `Insika::Wiring::GraphChat`, shared with `config/deployment.rb`'s own
        # registration of `run_persona_eval` (see `register_persona_eval_tool`
        # below).
        @chat_runtime = Insika::Wiring::GraphChat.new(graph: @graph)
        seed_default_model
        import_packs
      end

      # The graph's RubyLLM context — an isolated config dup that
      # answers #chat. nil only under the test stub, where the fallback is the
      # RubyLLM constant itself. Read by the specs and by anything a host wires
      # alongside this graph.
      attr_reader :llm

      # An imported profile, read back from the store (config-over-code
      # round-trip). Defaults to the primary agent.
      def profile(agent_id = nil)
        id = (agent_id || @definition.id).to_s
        @graph.profiles.fetch(id) ||
          (raise Insika::Error, "agent '#{id}' was not imported")
      end

      # One turn, in-process → the assistant's text. session_id nil = stateless
      # one-shot; a value threads multi-turn memory (created on first use).
      # `agent:` targets one agent of a system (default: the primary).
      def chat(message, session_id: nil, timeout: nil, agent: nil)
        @chat_runtime.chat(message, agent: (agent || @definition.id).to_s,
                                    session_id: session_id, timeout: timeout)
      end

      # Triggers a declared workflow and returns its OUTPUT (the typed value the
      # workflow returned), not the turn text. A schema violation on the input
      # raises here, synchronously, with no run created — same contract as
      # POST /v1/workflows/:name.
      def run_workflow(name, input:, agent:, timeout: nil)
        command = Insika::Command.build(
          :trigger_workflow, { workflow: name, agent: agent, input: input }, transport: :cli
        )
        outcome = @chat_runtime.run_command(command, session_id: nil, timeout: timeout)
        outcome.key?(:output) ? outcome[:output] : outcome[:text]
      end

      # Boot the control UI (/studio) + drop-in API (/v1). Blocks on the reactor.
      def serve(port:, host:, token:, **_opts)
        require_relative "server_boot"
        ServerBoot.new(self, port: port, host: host, token: token).run
      end

      # A named collaborator (settings_store, tool_store, …) the server boot reads.
      def component(name) = @components.fetch(name)

      private

      # --- graph assembly (mirrors config/deployment.rb, generically) ------

      def build_graph
        backend = @injected_backend || Insika::Wiring::Graph.backend_from_env
        # :workflow_allowlist joins the builtins here for the same reason the
        # minimal wiring registers it: this root CAN expose workflows. An agent
        # that never names one keeps `workflows_allow` nil = all (parity).
        spine = Insika::Wiring::Graph.spine(
          backend: backend,
          extra_policy_builtins: { workflow_allowlist: Insika::Policy::Builtin::WorkflowAllowlist }
        )
        c = build_components(backend, spine)
        @components = c

        graph = Insika::Wiring::Graph.build(
          spine: spine, profiles: c[:profile_source],
          tool_registry: c[:tool_registry], tool_catalog: c[:tool_catalog],
          skill_catalog: c[:skill_catalog], prompt_catalog: c[:prompt_catalog],
          guardrails: c[:guardrails], context_providers: context_providers(spine, c),
          edge_limiter: c[:edge_limiter],
          executor_extra: { settings_store: c[:settings_store], tool_trace_store: c[:tool_trace_store],
                            context_trace_store: c[:context_trace_store],
                            cache_series_store: c[:cache_series_store], llm: @llm }
        )
        register_authoring_commands(graph, c)
        register_workflows(graph)
        import_mcp_declarations(c)
        # `run_persona_eval` (C3.1): the SAME registration `config/deployment.rb`
        # does for its own graph — see `Wiring::Graph.register_persona_eval_tool`.
        # One implementation, both roots; this one just already has its
        # `golden_store`/`settings_store` at hand from `build_components`.
        Insika::Wiring::Graph.register_persona_eval_tool(
          graph, golden_store: Insika::GoldenStore.new(config_store: c[:config_store]),
          settings_store: c[:settings_store], llm: @llm
        )
        # Same boot step the server roots run: an installed `insika-plugin-*`
        # gem (or INSIKA_PLUGIN_DIR) extends a DSL-run agent too — a plugin
        # works everywhere or it is not a plugin. No bundled root here: the DSL
        # runs outside the repo checkout.
        Insika::Wiring::Graph.load_plugins(graph)
        graph
      end

      # Declared workflows land in the SAME registry a deployment uses, so a DSL
      # workflow is discoverable (`GET /v1/workflows`), schema-validated and
      # durable (its run IS a Task) exactly like a hand-wired one. The
      # :trigger_workflow command is registered only when there is something to
      # trigger — parity: a system without workflows behaves as before.
      def register_workflows(graph)
        declared = @definition.respond_to?(:workflows) ? Array(@definition.workflows) : []
        return if declared.empty?

        declared.each do |w|
          callable = WorkflowAdapter.new(block: w[:block], runtime: self)
          graph.workflow_registry.register(
            w[:name], callable,
            description: w[:description], input_schema: w[:input_schema], output_schema: w[:output_schema]
          )
        end

        graph.bus.register(:trigger_workflow, Insika::Commands::TriggerWorkflow.new(
                                                profiles: graph.profiles, session_store: graph.session_store,
                                                task_store: graph.task_store, executor: graph.executor,
                                                workflow_registry: graph.workflow_registry
                                              ))
      end

      # Upserts every DSL-declared `mcp` instance into the McpStore at boot.
      # Code is the TEMPLATE — transport/command/args/url/
      # description always follow the declaration — but `enabled` and the
      # credentials (`env`/`headers`) are the operator's once the instance
      # exists: an already-present record's own values are re-sent verbatim
      # instead of the DSL's, so a Studio/CLI/API edit made after boot is never
      # clobbered by the next restart (motor-vs-forja: the store's DATA wins).
      def import_mcp_declarations(c)
        declared = Array(@definition.mcp_instances)
        return if declared.empty?

        mcp_store = c[:mcp_store]
        declared.each do |decl|
          attrs = decl.dup
          existing = mcp_store.get_raw(attrs[:name])
          if existing
            attrs[:enabled] = existing["enabled"]
            attrs[:env] = existing["env"]
            attrs[:headers] = existing["headers"]
          end
          mcp_store.upsert(attrs)
        end
      end

      def build_components(backend, spine)
        config_store = Insika::ConfigStore.new(store: backend)
        settings_store = Insika::SettingsStore.new(config_store: config_store)
        provider_store = Insika::LLMProviderStore.new(config_store: config_store)
        tool_store = Insika::ToolStore.new(config_store: config_store)
        skill_store = Insika::SkillStore.new(config_store: config_store)
        mcp_store = Insika::McpStore.new(config_store: config_store)
        mcp_tool_registry = Insika::McpToolRegistry.new(mcp_store: mcp_store)
        tool_registry = Insika::OverlayToolRegistry.new(
          base: spine.code_tool_registry, tool_store: tool_store,
          http: Insika::HttpClient.new, event_stream: spine.event_stream,
          mcp_registry: mcp_tool_registry
        )
        {
          backend: backend, config_store: config_store,
          settings_store: settings_store, provider_store: provider_store,
          configurator: Insika::LLMConfigurator.new(provider_store: provider_store, configure: llm_configure),
          agent_file_store: Insika::AgentFileStore.new(config_store: config_store),
          skill_store: skill_store, tool_store: tool_store,
          system_file_store: Insika::SystemFileStore.new(config_store: config_store),
          mcp_store: mcp_store, mcp_tool_registry: mcp_tool_registry,
          tool_trace_store: Insika::ToolTraceStore.new(store: backend),
          context_trace_store: Insika::ContextTraceStore.new(store: backend),
          # the per-AGENT cache-hit series (the Studio agent-detail card).
          cache_series_store: Insika::CacheSeriesStore.new(store: backend),
          tool_registry: tool_registry,
          tool_catalog: Insika::ToolCatalog.new(tool_registry: tool_registry),
          skill_catalog: Insika::SkillCatalog.new([], store: skill_store),
          prompt_catalog: Insika::PromptCatalog.new([]),
          profile_source: Insika::StoredProfileSource.new(config_store: config_store),
          # the moderator/validator tiers ask a model too. A graph reading its
          # own key for the turn but the global one for a guardrail would be a
          # credential leak wearing the look of isolation.
          guardrails: Insika::Safety::Factory.new(settings_store: settings_store, llm: @llm),
          edge_limiter: Insika::EdgeLimiter.new(
            ledger: Insika::UsageLedger.new(store: backend), settings_store: settings_store,
            budget_ledger: spine.budget_ledger, event_stream: spine.event_stream
          )
        }
      end

      def context_providers(spine, c)
        [
          Insika::Context::Providers::Request.new,
          Insika::Context::Providers::Prompt.new(
            base: "", files: [], catalog: c[:prompt_catalog],
            agent_files: c[:agent_file_store], system_files: c[:system_file_store]
          ),
          Insika::Context::Providers::Skill.new(catalog: c[:skill_catalog]),
          Insika::Context::Providers::SkillTrigger.new(catalog: c[:skill_catalog]),
          Insika::Context::Providers::ToolSearch.new(catalog: c[:tool_catalog]),
          Insika::Context::Providers::Memory.new(store: spine.memory_store),
          Insika::Context::Providers::Session.new(session_store: spine.session_store)
        ] # NOT frozen: load_plugins appends plugin providers at boot
      end

      # The runtime-authoring surface a pack import needs (create_agent +
      # write_agent_file/skill/data_tool), plus the rest of the CRUD so /studio is
      # fully functional under #serve. Same handlers as config/deployment.rb.
      def register_authoring_commands(graph, c)
        bus = graph.bus
        es = graph.event_stream
        mem = graph.memory_store
        audit = graph.memory_audit_store
        bus.register(:create_agent, Insika::Commands::CreateAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:update_agent, Insika::Commands::UpdateAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:delete_agent, Insika::Commands::DeleteAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:set_agent_tools, Insika::Commands::SetAgentTools.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:write_agent_file, Insika::Commands::WriteAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:delete_agent_file, Insika::Commands::DeleteAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:restore_agent_file, Insika::Commands::RestoreAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:write_skill, Insika::Commands::WriteSkill.new(skill_store: c[:skill_store], skill_catalog: c[:skill_catalog], event_stream: es))
        bus.register(:set_skill_agents, Insika::Commands::SetSkillAgents.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:memory_put_fact, Insika::Commands::MemoryPutFact.new(memory_store: mem, event_stream: es, audit_store: audit))
        bus.register(:memory_forget_fact, Insika::Commands::MemoryForgetFact.new(memory_store: mem, event_stream: es, audit_store: audit))
        bus.register(:memory_add_note, Insika::Commands::MemoryAddNote.new(memory_store: mem, event_stream: es))
        # the LGPD access right — the Studio Customers drill exports.
        bus.register(:export_customer_memory, Insika::Commands::ExportCustomerMemory.new(memory_store: mem, event_stream: es))
        bus.register(:update_settings, Insika::Commands::UpdateSettings.new(settings_store: c[:settings_store], event_stream: es))
        bus.register(:upsert_llm_provider, Insika::Commands::UpsertLLMProvider.new(provider_store: c[:provider_store], configurator: c[:configurator], event_stream: es))
        bus.register(:delete_llm_provider, Insika::Commands::DeleteLLMProvider.new(provider_store: c[:provider_store], configurator: c[:configurator], event_stream: es))
        bus.register(:upsert_mcp, Insika::Commands::UpsertMcp.new(mcp_store: c[:mcp_store], mcp_registry: c[:mcp_tool_registry], event_stream: es))
        bus.register(:delete_mcp, Insika::Commands::DeleteMcp.new(mcp_store: c[:mcp_store], mcp_registry: c[:mcp_tool_registry], event_stream: es))
        bus.register(:refresh_mcp_tools, Insika::Commands::RefreshMcpTools.new(mcp_registry: c[:mcp_tool_registry], event_stream: es))
        bus.register(:write_system_file, Insika::Commands::WriteSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:delete_system_file, Insika::Commands::DeleteSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:restore_system_file, Insika::Commands::RestoreSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:write_data_tool, Insika::Commands::WriteDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
        bus.register(:delete_data_tool, Insika::Commands::DeleteDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
        bus.register(:restore_data_tool, Insika::Commands::RestoreDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
        bus.register(:write_concept, Insika::Commands::WriteConcept.new(knowledge_store: graph.knowledge_store, event_stream: es))
        bus.register(:delete_concept, Insika::Commands::DeleteConcept.new(knowledge_store: graph.knowledge_store, event_stream: es))
        bus.register(:restore_concept, Insika::Commands::RestoreConcept.new(knowledge_store: graph.knowledge_store, event_stream: es))
      end

      # --- RubyLLM configuration ------------------------------------------

      def provider_name
        (@definition.runtime_options[:provider] || @pack.config[:provider] || "deepseek").to_s
      end

      # Every distinct provider the system uses, primary first. A fan-out system
      # routinely mixes providers (one specialist on Anthropic, another on
      # OpenAI), and configuring only the primary would leave the others without
      # a key — a 401 at the first delegation, far from its cause.
      def provider_names
        ([provider_name] + @packs.filter_map { |p| Insika::Coercion.presence(p.config[:provider])&.to_s }).uniq
      end

      # the graph's credentials belong to the graph. `RubyLLM.context`
      # is an isolated dup of the config that answers #chat, so two graphs in one
      # process no longer overwrite each other's keys: the global
      # `RubyLLM.configure` is a single slot PER PROVIDER, and the loser of that
      # race got no error, just the other tenant's key.
      #
      # Returns nil under the test stub (no #context) — every consumer falls back
      # to the RubyLLM constant, which is exactly the old behavior.
      def build_llm_context
        return nil unless RubyLLM.respond_to?(:context)

        primary = provider_name
        RubyLLM.context do |cfg|
          provider_names.each do |provider|
            # The explicit api_key/api_base belong to the PRIMARY provider; the
            # others resolve from the conventional <PROVIDER>_API_KEY.
            explicit = provider == primary
            key = (explicit ? @definition.runtime_options[:api_key] : nil) || ENV["#{provider.upcase}_API_KEY"]
            base = (explicit ? @definition.runtime_options[:api_base] : nil) || default_base_for(provider)
            apply_llm(cfg, "#{provider}_api_key", key)
            apply_llm(cfg, "#{provider}_api_base", base)
          end
          cfg.request_timeout = 120
          cfg.max_retries = 2
        end
      end

      # The LLMConfigurator's target (Studio: edit a provider key, no restart).
      # Scoped to THIS graph's context — a `RubyLLM.configure` here would reach
      # into every other graph in the process, which is the leak exists to
      # close. nil = no context (test stub) -> the configurator's own global
      # default, unchanged.
      def llm_configure
        return nil if @llm.nil?

        context = @llm
        ->(&blk) { blk.call(context.config) }
      end

      def apply_llm(cfg, setter, value)
        return if value.nil? || value.to_s.empty?

        writer = "#{setter}="
        cfg.public_send(writer, value) if cfg.respond_to?(writer)
      end

      # Known convenience default (DeepSeek's OpenAI-compatible base); other
      # providers use the gem's default unless api_base is given.
      def default_base_for(provider)
        provider == "deepseek" ? "https://api.deepseek.com/v1" : nil
      end

      # Seed the platform default model/provider so a modelless agent works too.
      def seed_default_model
        c = @components
        return unless Insika::Coercion.presence(c[:settings_store].get["default_model"]).nil?

        model = @pack.config[:model]
        return if model.nil?

        c[:settings_store].update("default_model" => model.to_s, "default_provider" => provider_name)
      end

      # One import per agent, in declaration order. Order is not significant for
      # delegation: `SubagentGraph.validate!` treats an unknown child id as a
      # LEAF, so a parent declared before its children imports cleanly and the
      # reference resolves once they land.
      def import_packs
        importer = Insika::PackImporter.new(bus: @graph.bus, profiles: @components[:profile_source])
        @packs.each { |pack| importer.import(pack) }
      end
    end
  end
end

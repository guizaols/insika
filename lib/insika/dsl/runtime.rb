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
      TERMINAL = %i[task_completed task_failed task_cancelled].freeze

      # graph: the assembled Wiring::Graph::Result; pack: the PRIMARY imported
      # Pack; packs: every imported Pack (one per agent — a System has N, a
      # Definition has one). All read by the server boot and the specs.
      attr_reader :graph, :pack, :packs

      # `definition` is a Definition (one agent) or a System (N agents). Both
      # answer #pack/#id; a System also answers #packs. Duck-typed on purpose:
      # the runtime does not care how many agents it hosts, only that each one
      # arrives as an ordinary Pack.
      def initialize(definition)
        @definition = definition
        @packs = (definition.respond_to?(:packs) ? Array(definition.packs) : [definition.pack]).freeze
        @pack = @packs.first
        @graph = build_graph
        configure_llm
        seed_default_model
        import_packs
      end

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
        command = Insika::Command.build(
          :send_message,
          { agent: (agent || @definition.id).to_s, message: message, session_id: session_id },
          transport: :cli
        )
        run_command(command, session_id: session_id, timeout: timeout)[:text]
      end

      # Triggers a declared workflow and returns its OUTPUT (the typed value the
      # workflow returned), not the turn text. A schema violation on the input
      # raises here, synchronously, with no run created — same contract as
      # POST /v1/workflows/:name.
      def run_workflow(name, input:, agent:, timeout: nil)
        command = Insika::Command.build(
          :trigger_workflow, { workflow: name, agent: agent, input: input }, transport: :cli
        )
        outcome = run_command(command, session_id: nil, timeout: timeout)
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

      # Dispatch + drain, shared by a turn and a workflow run: subscribe BEFORE
      # dispatching (the fiber may emit eagerly), bind to the task, read to the
      # terminal event. A synchronous handler error (unknown agent/workflow, bad
      # input against the schema) propagates from `dispatch` untouched — the
      # caller sees the real ValidationError/NotFoundError, not a turn failure.
      def run_command(command, session_id:, timeout:)
        require "async"
        outcome = {}
        rejected = nil
        Async do |task|
          serving = !session_id.nil?
          @graph.executor.supervised = true if serving
          ensure_session(session_id) if session_id
          sub = @graph.event_stream.subscribe
          res = begin
            @graph.bus.dispatch(command)
          rescue StandardError => e
            # CAPTURED, not re-raised inside the reactor: letting it escape the
            # Async block logs "Task may have ended with unhandled exception" —
            # alarming noise for a DOCUMENTED rejection (a schema violation, an
            # unknown agent). Re-raised verbatim below, outside the reactor.
            sub.close
            rejected = e
            next
          end
          sub.bind(task_id: res[:task_id])
          drain(sub, outcome, task, timeout)
          teardown_serving if serving
        end.wait
        raise rejected if rejected
        raise Insika::Error, "turn #{outcome[:error]}" if outcome[:error]

        outcome
      end

      # Reads the stream until this turn reaches a terminal event, then stops.
      # A workflow run also carries its typed OUTPUT, which is not the turn text.
      def drain(sub, outcome, task, timeout)
        reader = task.async do
          sub.each do |ev|
            case ev.type
            when :task_completed      then outcome[:text] = ev.data[:content].to_s
            when :workflow_completed  then outcome[:output] = ev.data[:output]
            when :task_failed         then outcome[:error] = "failed: #{ev.data[:message] || ev.data[:error]}"
            when :task_cancelled      then outcome[:error] = "cancelled"
            end
            sub.close if TERMINAL.include?(ev.type)
          end
        end
        timeout ? task.with_timeout(timeout) { reader.wait } : reader.wait
      rescue Async::TimeoutError
        outcome[:error] = "timed out after #{timeout}s"
        sub.close
      end

      def ensure_session(session_id)
        @graph.session_store.find(session_id) || @graph.session_store.create(id: session_id, vars: {})
      end

      def teardown_serving
        @graph.executor.stop_session_actors
        @graph.executor.instance_variable_get(:@supervisor)&.stop
      end

      # --- graph assembly (mirrors config/deployment.rb, generically) ------

      def build_graph
        backend = Insika::Wiring::Graph.backend_from_env
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
          executor_extra: { settings_store: c[:settings_store], tool_trace_store: c[:tool_trace_store] }
        )
        register_authoring_commands(graph, c)
        register_workflows(graph)
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

      def build_components(backend, spine)
        config_store = Insika::ConfigStore.new(store: backend)
        settings_store = Insika::SettingsStore.new(config_store: config_store)
        provider_store = Insika::LLMProviderStore.new(config_store: config_store)
        tool_store = Insika::ToolStore.new(config_store: config_store)
        skill_store = Insika::SkillStore.new(config_store: config_store)
        tool_registry = Insika::OverlayToolRegistry.new(
          base: spine.code_tool_registry, tool_store: tool_store,
          http: Insika::HttpClient.new, event_stream: spine.event_stream
        )
        {
          backend: backend, config_store: config_store,
          settings_store: settings_store, provider_store: provider_store,
          configurator: Insika::LLMConfigurator.new(provider_store: provider_store),
          agent_file_store: Insika::AgentFileStore.new(config_store: config_store),
          skill_store: skill_store, tool_store: tool_store,
          system_file_store: Insika::SystemFileStore.new(config_store: config_store),
          mcp_store: Insika::McpStore.new(config_store: config_store),
          tool_trace_store: Insika::ToolTraceStore.new(store: backend),
          tool_registry: tool_registry,
          tool_catalog: Insika::ToolCatalog.new(tool_registry: tool_registry),
          skill_catalog: Insika::SkillCatalog.new([], store: skill_store),
          prompt_catalog: Insika::PromptCatalog.new([]),
          profile_source: Insika::StoredProfileSource.new(config_store: config_store),
          guardrails: Insika::Safety::Factory.new(settings_store: settings_store),
          edge_limiter: Insika::EdgeLimiter.new(
            ledger: Insika::UsageLedger.new(store: backend), settings_store: settings_store
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
          Insika::Context::Providers::ToolSearch.new(catalog: c[:tool_catalog]),
          Insika::Context::Providers::Memory.new(store: spine.memory_store),
          Insika::Context::Providers::Session.new(session_store: spine.session_store)
        ].freeze
      end

      # The runtime-authoring surface a pack import needs (create_agent +
      # write_agent_file/skill/data_tool), plus the rest of the CRUD so /studio is
      # fully functional under #serve. Same handlers as config/deployment.rb.
      def register_authoring_commands(graph, c)
        bus = graph.bus
        es = graph.event_stream
        mem = graph.memory_store
        bus.register(:create_agent, Insika::Commands::CreateAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:update_agent, Insika::Commands::UpdateAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:delete_agent, Insika::Commands::DeleteAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:set_agent_tools, Insika::Commands::SetAgentTools.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:write_agent_file, Insika::Commands::WriteAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:delete_agent_file, Insika::Commands::DeleteAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:restore_agent_file, Insika::Commands::RestoreAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:write_skill, Insika::Commands::WriteSkill.new(skill_store: c[:skill_store], skill_catalog: c[:skill_catalog], event_stream: es))
        bus.register(:set_skill_agents, Insika::Commands::SetSkillAgents.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:memory_put_fact, Insika::Commands::MemoryPutFact.new(memory_store: mem, event_stream: es))
        bus.register(:memory_forget_fact, Insika::Commands::MemoryForgetFact.new(memory_store: mem, event_stream: es))
        bus.register(:memory_add_note, Insika::Commands::MemoryAddNote.new(memory_store: mem, event_stream: es))
        bus.register(:update_settings, Insika::Commands::UpdateSettings.new(settings_store: c[:settings_store], event_stream: es))
        bus.register(:upsert_llm_provider, Insika::Commands::UpsertLLMProvider.new(provider_store: c[:provider_store], configurator: c[:configurator], event_stream: es))
        bus.register(:delete_llm_provider, Insika::Commands::DeleteLLMProvider.new(provider_store: c[:provider_store], configurator: c[:configurator], event_stream: es))
        bus.register(:upsert_mcp, Insika::Commands::UpsertMcp.new(mcp_store: c[:mcp_store], event_stream: es))
        bus.register(:delete_mcp, Insika::Commands::DeleteMcp.new(mcp_store: c[:mcp_store], event_stream: es))
        bus.register(:write_system_file, Insika::Commands::WriteSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:delete_system_file, Insika::Commands::DeleteSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:restore_system_file, Insika::Commands::RestoreSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:write_data_tool, Insika::Commands::WriteDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
        bus.register(:delete_data_tool, Insika::Commands::DeleteDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
        bus.register(:restore_data_tool, Insika::Commands::RestoreDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
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

      def configure_llm
        return unless RubyLLM.respond_to?(:configure) # absent under the test stub

        primary = provider_name
        RubyLLM.configure do |cfg|
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

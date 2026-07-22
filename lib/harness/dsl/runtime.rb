# frozen_string_literal: true

require "ruby_llm"

module Harness
  module DSL
    # The live graph behind a Definition: it assembles the SAME authoring graph a
    # concrete deployment does (Harness::Wiring::Graph + the runtime-authoring
    # command surface), configures RubyLLM, and imports the definition's pack via
    # the standard PackImporter. From there the agent is indistinguishable from one
    # provisioned by any other pack — chat and serve just drive the normal path.
    #
    # Built lazily by Definition#runtime, so `require "harness"` never pays for
    # ruby_llm or the HTTP server.
    class Runtime
      TERMINAL = %i[task_completed task_failed task_cancelled].freeze

      # graph: the assembled Wiring::Graph::Result; pack: the imported Pack. Both
      # read by the server boot and the specs.
      attr_reader :graph, :pack

      def initialize(definition)
        @definition = definition
        @pack = definition.pack
        @graph = build_graph
        configure_llm
        seed_default_model
        import_pack
      end

      # The imported profile, read back from the store (config-over-code round-trip).
      def profile
        @graph.profiles.fetch(@definition.id) ||
          (raise Harness::Error, "agent '#{@definition.id}' was not imported")
      end

      # One turn, in-process → the assistant's text. session_id nil = stateless
      # one-shot; a value threads multi-turn memory (created on first use).
      def chat(message, session_id: nil, timeout: nil)
        require "async"
        outcome = { text: nil, error: nil }
        Async do |task|
          serving = !session_id.nil?
          @graph.executor.supervised = true if serving
          ensure_session(session_id) if session_id
          sub = @graph.event_stream.subscribe
          res = dispatch_turn(message, session_id)
          sub.bind(task_id: res[:task_id])
          drain(sub, outcome, task, timeout)
          teardown_serving if serving
        end.wait
        raise Harness::Error, "turn #{outcome[:error]}" if outcome[:error]

        outcome[:text]
      end

      # Boot the control UI (/studio) + drop-in API (/v1). Blocks on the reactor.
      def serve(port:, host:, token:, **_opts)
        require_relative "server_boot"
        ServerBoot.new(self, port: port, host: host, token: token).run
      end

      # A named collaborator (settings_store, tool_store, …) the server boot reads.
      def component(name) = @components.fetch(name)

      private

      def dispatch_turn(message, session_id)
        @graph.bus.dispatch(Harness::Command.build(
                              :send_message,
                              { agent: @definition.id, message: message, session_id: session_id },
                              transport: :cli
                            ))
      end

      # Reads the stream until this turn reaches a terminal event, then stops.
      def drain(sub, outcome, task, timeout)
        reader = task.async do
          sub.each do |ev|
            case ev.type
            when :task_completed then outcome[:text] = ev.data[:content].to_s
            when :task_failed    then outcome[:error] = "failed: #{ev.data[:message] || ev.data[:error]}"
            when :task_cancelled then outcome[:error] = "cancelled"
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
        backend = Harness::Wiring::Graph.backend_from_env
        spine = Harness::Wiring::Graph.spine(backend: backend)
        c = build_components(backend, spine)
        @components = c

        graph = Harness::Wiring::Graph.build(
          spine: spine, profiles: c[:profile_source],
          tool_registry: c[:tool_registry], tool_catalog: c[:tool_catalog],
          skill_catalog: c[:skill_catalog], prompt_catalog: c[:prompt_catalog],
          guardrails: c[:guardrails], context_providers: context_providers(spine, c),
          edge_limiter: c[:edge_limiter],
          executor_extra: { settings_store: c[:settings_store], tool_trace_store: c[:tool_trace_store] }
        )
        register_authoring_commands(graph, c)
        graph
      end

      def build_components(backend, spine)
        config_store = Harness::ConfigStore.new(store: backend)
        settings_store = Harness::SettingsStore.new(config_store: config_store)
        provider_store = Harness::LLMProviderStore.new(config_store: config_store)
        tool_store = Harness::ToolStore.new(config_store: config_store)
        skill_store = Harness::SkillStore.new(config_store: config_store)
        tool_registry = Harness::OverlayToolRegistry.new(
          base: spine.code_tool_registry, tool_store: tool_store,
          http: Harness::HttpClient.new, event_stream: spine.event_stream
        )
        {
          backend: backend, config_store: config_store,
          settings_store: settings_store, provider_store: provider_store,
          configurator: Harness::LLMConfigurator.new(provider_store: provider_store),
          agent_file_store: Harness::AgentFileStore.new(config_store: config_store),
          skill_store: skill_store, tool_store: tool_store,
          system_file_store: Harness::SystemFileStore.new(config_store: config_store),
          mcp_store: Harness::McpStore.new(config_store: config_store),
          tool_trace_store: Harness::ToolTraceStore.new(store: backend),
          tool_registry: tool_registry,
          tool_catalog: Harness::ToolCatalog.new(tool_registry: tool_registry),
          skill_catalog: Harness::SkillCatalog.new([], store: skill_store),
          prompt_catalog: Harness::PromptCatalog.new([]),
          profile_source: Harness::StoredProfileSource.new(config_store: config_store),
          guardrails: Harness::Safety::Factory.new(settings_store: settings_store),
          edge_limiter: Harness::EdgeLimiter.new(
            ledger: Harness::UsageLedger.new(store: backend), settings_store: settings_store
          )
        }
      end

      def context_providers(spine, c)
        [
          Harness::Context::Providers::Request.new,
          Harness::Context::Providers::Prompt.new(
            base: "", files: [], catalog: c[:prompt_catalog],
            agent_files: c[:agent_file_store], system_files: c[:system_file_store]
          ),
          Harness::Context::Providers::Skill.new(catalog: c[:skill_catalog]),
          Harness::Context::Providers::ToolSearch.new(catalog: c[:tool_catalog]),
          Harness::Context::Providers::Memory.new(store: spine.memory_store),
          Harness::Context::Providers::Session.new(session_store: spine.session_store)
        ].freeze
      end

      # The runtime-authoring surface a pack import needs (create_agent +
      # write_agent_file/skill/data_tool), plus the rest of the CRUD so /studio is
      # fully functional under #serve. Same handlers as config/deployment.rb.
      def register_authoring_commands(graph, c)
        bus = graph.bus
        es = graph.event_stream
        mem = graph.memory_store
        bus.register(:create_agent, Harness::Commands::CreateAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:update_agent, Harness::Commands::UpdateAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:delete_agent, Harness::Commands::DeleteAgent.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:set_agent_tools, Harness::Commands::SetAgentTools.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:write_agent_file, Harness::Commands::WriteAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:delete_agent_file, Harness::Commands::DeleteAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:restore_agent_file, Harness::Commands::RestoreAgentFile.new(profile_source: c[:profile_source], agent_file_store: c[:agent_file_store], event_stream: es))
        bus.register(:write_skill, Harness::Commands::WriteSkill.new(skill_store: c[:skill_store], skill_catalog: c[:skill_catalog], event_stream: es))
        bus.register(:set_skill_agents, Harness::Commands::SetSkillAgents.new(profile_source: c[:profile_source], event_stream: es))
        bus.register(:memory_put_fact, Harness::Commands::MemoryPutFact.new(memory_store: mem, event_stream: es))
        bus.register(:memory_forget_fact, Harness::Commands::MemoryForgetFact.new(memory_store: mem, event_stream: es))
        bus.register(:memory_add_note, Harness::Commands::MemoryAddNote.new(memory_store: mem, event_stream: es))
        bus.register(:update_settings, Harness::Commands::UpdateSettings.new(settings_store: c[:settings_store], event_stream: es))
        bus.register(:upsert_llm_provider, Harness::Commands::UpsertLLMProvider.new(provider_store: c[:provider_store], configurator: c[:configurator], event_stream: es))
        bus.register(:delete_llm_provider, Harness::Commands::DeleteLLMProvider.new(provider_store: c[:provider_store], configurator: c[:configurator], event_stream: es))
        bus.register(:upsert_mcp, Harness::Commands::UpsertMcp.new(mcp_store: c[:mcp_store], event_stream: es))
        bus.register(:delete_mcp, Harness::Commands::DeleteMcp.new(mcp_store: c[:mcp_store], event_stream: es))
        bus.register(:write_system_file, Harness::Commands::WriteSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:delete_system_file, Harness::Commands::DeleteSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:restore_system_file, Harness::Commands::RestoreSystemFile.new(system_file_store: c[:system_file_store], event_stream: es))
        bus.register(:write_data_tool, Harness::Commands::WriteDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
        bus.register(:delete_data_tool, Harness::Commands::DeleteDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
        bus.register(:restore_data_tool, Harness::Commands::RestoreDataTool.new(tool_store: c[:tool_store], registry: c[:tool_registry], tool_catalog: c[:tool_catalog], event_stream: es))
      end

      # --- RubyLLM configuration ------------------------------------------

      def provider_name
        (@definition.runtime_options[:provider] || @pack.config[:provider] || "deepseek").to_s
      end

      def configure_llm
        return unless RubyLLM.respond_to?(:configure) # absent under the test stub

        provider = provider_name
        key = @definition.runtime_options[:api_key] || ENV["#{provider.upcase}_API_KEY"]
        base = @definition.runtime_options[:api_base] || default_base_for(provider)
        RubyLLM.configure do |cfg|
          apply_llm(cfg, "#{provider}_api_key", key)
          apply_llm(cfg, "#{provider}_api_base", base)
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
        return unless Harness::Coercion.presence(c[:settings_store].get["default_model"]).nil?

        model = @pack.config[:model]
        return if model.nil?

        c[:settings_store].update("default_model" => model.to_s, "default_provider" => provider_name)
      end

      def import_pack
        Harness::PackImporter.new(bus: @graph.bus, profiles: @components[:profile_source]).import(@pack)
      end
    end
  end
end

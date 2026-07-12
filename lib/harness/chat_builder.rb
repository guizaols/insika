# frozen_string_literal: true

module Harness
  # Monta o chat do turno (estágios 5-7 da pipeline): instruções, partição
  # eager/deferred de tools, tools de sistema (tool_search/load_skill/remember),
  # histórico e callbacks. Extraído do Executor para que ele coordene a pipeline
  # sem carregar também a cola do RubyLLM.
  #
  # O Executor cria o chat (estágio 6, boundary do RubyLLM) e passa-o aqui para
  # ser configurado; a numeração de eventos (seq monotônico por task) continua no
  # Executor, injetada como o callable `emit`.
  class ChatBuilder
    def initialize(tool_registry:, skill_catalog:, checkpoint_store:, event_stream:,
                   hooks:, tool_catalog: nil, memory_store: nil)
      @tool_registry = tool_registry
      @skill_catalog = skill_catalog
      @checkpoint_store = checkpoint_store
      @event_stream = event_stream
      @hooks = hooks
      @tool_catalog = tool_catalog
      @memory_store = memory_store
    end

    # Configura um chat já criado com o contexto (estágio 2) e a Resolution
    # (estágio 3), semeia o histórico e liga os callbacks. `emit` é o emissor do
    # Executor (correlação seq+task), chamado como emit.call(type, data). As tools
    # de sistema (Tools::ToolSearch/LoadSkill/Remember) já foram carregadas lazy
    # pelo Executor#create_chat antes de chegar aqui.
    def assemble(chat, state, emit:)
      configure_chat(chat, state)
      seed_history(chat, Array(state.context.history))
      wire_callbacks(chat, state, emit)
      chat
    end

    # Monta o chat com o contexto (estágio 2) e as tools da Resolution (estágio 3).
    def configure_chat(chat, state)
      system = state.context.system.to_s
      chat.with_instructions(system) unless system.empty?

      tools = Array(state.allowed_tools).dup

      # Tool Search: a partição só roda com @tool_catalog presente (paridade
      # quando nil — o `&&` curto-circuita antes de ler `.name`). `deferred_allowed`
      # = allowed_tools ∩ tools_deferred. O catálogo <available_tools> vem do
      # Context::Providers::ToolSearch (estágio 2); aqui só decidimos chat.tools.
      deferred_allowed = if @tool_catalog
                           Array(state.profile.tools_deferred).map(&:to_s) &
                             tools.map { |t| t.name.to_s }
                         else
                           []
                         end

      unless deferred_allowed.empty?
        tools.reject! { |t| deferred_allowed.include?(t.name.to_s) }
        # tool de sistema (fora da allowlist), como load_skill — nunca envelopada.
        tools << Tools::ToolSearch.new(@tool_catalog, deferred_allowed, chat,
                                       tool_registry: @tool_registry,
                                       checkpoint_store: @checkpoint_store,
                                       event_stream: @event_stream, state: state)
      end

      # load_skill é default de sistema (fora da allowlist), senão o progressive
      # disclosure quebra. allowed_skills vem da Resolution (policy).
      skill_names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
      tools << Tools::LoadSkill.new(@skill_catalog, skill_names) unless skill_names.empty?

      # remember é tool de sistema de escrita da memória — cabeada só com
      # @memory_store presente E profile.memory (gate duplo). Nunca envelopada.
      if @memory_store && state.profile.memory
        tools << Tools::Remember.new(@memory_store, state.tenant,
                                     event_stream: @event_stream, state: state)
      end

      chat.with_tools(*tools) unless tools.empty?

      chat
    end

    # Histórico vem do contexto/checkpoint. O shape {role:, content:} tolera
    # chaves string (JSON dos stores).
    def seed_history(chat, messages)
      Array(messages).each do |m|
        chat.add_message(role: (m[:role] || m["role"]).to_sym,
                         content: m[:content] || m["content"])
      end
    end

    # Callbacks aditivos do RubyLLM viram eventos. load_skill vira
    # :skill_activated. Acrescenta o contador max_tool_calls: o loop é do RubyLLM;
    # aqui só contamos e abortamos.
    def wire_callbacks(chat, state, emit)
      tool_calls = 0
      max_tool_calls = state.profile.limits[:max_tool_calls] || 50
      last_tool_name = nil

      chat.before_tool_call do |tool_call|
        # correlação call<->decorator (side-effects/skip) — 1ª linha.
        state.current_tool_call = tool_call
        # guard-rail max_tool_calls: fica inline (não como hook registrado) porque
        # o Hooks é compartilhado entre turnos e não tem unregister.
        tool_calls += 1
        if tool_calls > max_tool_calls
          raise Harness::TimeoutError.new("limite de tool calls excedido (#{max_tool_calls})",
                                          stage: :tool_limit)
        end

        # par :tool: os callbacks do RubyLLM são aditivos — o subject alterado
        # alimenta hooks seguintes e os eventos, mas não reescreve a call que o
        # modelo executa. Exceção de hook aqui aborta o turno.
        tool_call = @hooks.run_before(:tool, tool_call)

        last_tool_name = tool_call.name.to_s
        if last_tool_name == "load_skill"
          args = tool_call.arguments || {}
          emit.call(:skill_activated, { name: args["name"] || args[:name] })
        else
          emit.call(:tool_call, { name: tool_call.name, arguments: tool_call.arguments })
        end
      end

      chat.after_tool_result do |result|
        result = @hooks.run_after(:tool, result)
        emit.call(:tool_result, { name: last_tool_name, result: result.to_s })
      end
    end
  end
end

# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    # Nível 2 do progressive disclosure de TOOLS (análogo do LoadSkill):
    # busca no catálogo de deferred e PROMOVE as relevantes para o chat vivo via
    # chat.with_tools (verificado propagar no round seguinte do mesmo `ask`
    # no ruby_llm 1.16). `require "ruby_llm"` fica NESTE arquivo (herda de
    # RubyLLM::Tool) — não entra em lib/harness.rb; o Executor o carrega lazy no
    # configure_chat (como o LoadSkill).
    class ToolSearch < RubyLLM::Tool
      description "Busca e habilita ferramentas adicionais por descrição da necessidade"
      param :query, desc: "O que você precisa fazer (ex.: 'enviar email', 'gerar fatura')"

      # RubyLLM::Tool#name deriva de self.class.name — p/ classe aninhada
      # (Harness::Tools::ToolSearch) produz "harness--tools--tool_search", não
      # "tool_search". Override explícito: o nome que o modelo chama tem que casar
      # com o catálogo/docs/testes.
      def name = "tool_search"

      def initialize(catalog, deferred_allowed, chat, tool_registry:, event_stream:,
                     checkpoint_store:, state:)
        @catalog = catalog
        @deferred_allowed = Array(deferred_allowed).map(&:to_s)
        @chat = chat
        @tool_registry = tool_registry
        @event_stream = event_stream
        @checkpoint_store = checkpoint_store
        @state = state
        @promoted = [] # nomes já promovidos NESTE chat — idempotência
        super()
      end

      def execute(query:)
        matches = @catalog.search(query, within: @deferred_allowed)
        emit_tool_search(query, matches.map(&:name))
        if matches.empty?
          return { matched: [], message: "nenhuma ferramenta encontrada para '#{query}'" }
        end

        new_matches = matches.reject { |m| @promoted.include?(m.name) }
        promote(new_matches) unless new_matches.empty?

        { matched: matches.map { |m| describe(m) } }
      end

      private

      # Instancia (via tool_registry), embrulha no MESMO ToolEnvelope das eager
      # (timeout do profile + skip_side_effects do state) e promove via
      # chat.with_tools. NotFoundError (catálogo desalinhado) descarta só
      # aquele match — a busca não quebra.
      def promote(entries)
        timeout = @state.profile.limits[:tool_timeout] || 60
        wrapped = entries.filter_map do |entry|
          tool = @tool_registry.resolve(entry.name)
          @promoted << entry.name
          ToolEnvelope.new(tool, state: @state, checkpoint_store: @checkpoint_store,
                                 tool_registry: @tool_registry, timeout: timeout,
                                 skip_side_effects: Array(@state.skip_side_effects))
        rescue Harness::NotFoundError
          nil
        end
        @chat.with_tools(*wrapped) unless wrapped.empty?
      end

      # Espelha :skill_activated, mas emitido pela própria tool (tem event_stream/
      # state no construtor). Sem `seq` monotônico (privado ao Executor) — gap
      # documentado, não bloqueia.
      def emit_tool_search(query, matched_names)
        @event_stream.emit(Harness::Event.new(
                             type: :tool_search,
                             data: { query: query, matched: matched_names },
                             meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                           ))
      end

      def describe(entry)
        tool = @tool_registry.resolve(entry.name)
        {
          name: entry.name,
          description: entry.description,
          parameters: tool.parameters.transform_values do |p|
            { type: p.type, description: p.description, required: p.required }
          end
        }
      rescue Harness::NotFoundError
        { name: entry.name, description: entry.description, parameters: {} }
      end
    end
  end
end

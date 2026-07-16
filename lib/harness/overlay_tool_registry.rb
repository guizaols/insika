# frozen_string_literal: true

module Harness
  # Registry de tools DINÂMICA: compõe a registry de CÓDIGO (base, montada no boot,
  # imutável) com as tools POR DADOS do ToolStore. Drop-in do ToolRegistry — o
  # Executor/ToolCatalog/ToolEnvelope só usam entries/resolve/side_effect?. Fase 5,
  # Etapa B / D2.
  #
  # Regras:
  #   - COLISÃO: a base (código) SEMPRE vence — uma data-tool não pode sequestrar
  #     o nome de uma tool de código (segurança, R3). O Command de autoria também
  #     recusa criar com nome colidente (code_tool?), mas a defesa fica aqui.
  #   - HOT: `reload` re-lê o store e troca o índice dinâmico atomicamente — uma
  #     data-tool nova/editada vale no próximo turno sem restart (F5), espelhando
  #     o SkillCatalog.reload. Um turno em andamento já capturou o índice.
  #   - PARIDADE (NF1): ToolStore vazio ⇒ entries/resolve/side_effect? idênticos à
  #     base pura. A base (config/wiring.rb) sequer usa o overlay — zero regressão.
  #
  # As data-tools entram como Registry::Entry NORMAIS (optional: false) — obedecem
  # ao mesmo allow/deny por agente das tools de código; a exposição é do operador
  # (matriz /tools), não automática por ser "por dados".
  class OverlayToolRegistry
    def initialize(base:, tool_store:, http:, egress: Harness::EgressGuard, egress_options: {}, event_stream: nil)
      @base = base
      @tool_store = tool_store
      @http = http
      @egress = egress
      @egress_options = egress_options
      @event_stream = event_stream
    end

    # Base + dinâmicas, exceto dinâmicas que colidem com a base (base vence).
    def entries
      @base.entries + dynamic.reject { |e| code_tool?(e.name) }
    end

    def names
      (@base.names + dynamic.map(&:name)).uniq
    end

    # -> instância (base vence) | raise NotFoundError.
    def resolve(name)
      key = name.to_s
      return @base.resolve(key) if code_tool?(key)

      entry = dynamic.find { |e| e.name == key }
      raise Harness::NotFoundError, "'#{name}' não registrada em #{self.class}" unless entry

      entry.factory.call
    end

    # -> bool; consumido pelo ToolEnvelope (checkpoint/skip-on-resume). Base vence.
    def side_effect?(name)
      key = name.to_s
      return @base.side_effect?(key) if code_tool?(key)

      entry = dynamic.find { |e| e.name == key }
      entry ? !!entry.metadata[:side_effect] : false
    end

    # Troca atômica do índice dinâmico (após escrita/remoção de data-tool).
    def reload
      @dynamic = build_dynamic
      self
    end

    # É uma tool de CÓDIGO (base)? Usado pela validação do Command de autoria.
    def code_tool?(name) = @base.names.include?(name.to_s)

    private

    def dynamic
      @dynamic ||= build_dynamic
    end

    def build_dynamic
      @tool_store.all_raw.filter_map { |raw| entry_for(raw) }
    end

    def entry_for(raw)
      definition = Harness::ToolDefinition.from_h(raw)
      Harness::Registry::Entry.new(
        name: definition.name, plugin: "data-tools",
        metadata: { optional: false, side_effect: definition.side_effect,
                    group: definition.group, tags: definition.tags },
        factory: -> { build_tool(definition) }
      )
    rescue Harness::ValidationError => e
      warn "[overlay-tools] definição inválida ignorada: #{e.message}"
      nil
    end

    # require lazy: DataDefinedTool herda RubyLLM::Tool (puxa a gem) -> fora do
    # load-time do harness.rb, carregado na 1ª instância (turn time).
    def build_tool(definition)
      require_relative "tools/data_defined_tool"
      Harness::Tools::DataDefinedTool.new(
        definition: definition, http: @http, egress: @egress,
        egress_options: @egress_options, event_stream: @event_stream
      )
    end
  end
end

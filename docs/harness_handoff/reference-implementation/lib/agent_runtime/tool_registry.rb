# frozen_string_literal: true

module AgentRuntime
  # Registro dinâmico de tools (análogo ao api.registerTool + contracts.tools
  # do OpenClaw). O nome é a chave; o factory devolve a tool (classe ou
  # instância — RubyLLM aceita ambos em with_tools).
  #
  # required (optional: false) -> sempre disponível, salvo deny.
  # optional (optional: true)  -> só quando o agente faz opt-in via allow.
  class ToolRegistry
    Entry = Data.define(:name, :optional, :plugin, :factory)

    def initialize
      @entries = {}
    end

    def register(name, klass = nil, optional: false, plugin: nil, &block)
      name = name.to_s
      factory = block || -> { klass }
      @entries[name] = Entry.new(name: name, optional: optional, plugin: plugin, factory: factory)
      self
    end

    def names
      @entries.keys
    end

    # Política aplicada ANTES da chamada ao modelo (estilo OpenClaw): o que
    # sai daqui é exatamente o que o modelo enxerga.
    def resolve(profile)
      selected = @entries.keys

      # optional exige opt-in
      selected = selected.select do |n|
        !@entries[n].optional || profile.tool_opted_in?(n)
      end

      # allow não-vazia = conjunto final
      allow = profile.tools_allow
      selected &= allow if allow && !allow.empty?

      # deny sempre vence
      selected -= Array(profile.tools_deny)

      selected.map { |n| @entries[n].factory.call }
    end
  end
end

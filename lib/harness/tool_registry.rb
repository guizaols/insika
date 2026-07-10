# frozen_string_literal: true

module Harness
  # Registro dinâmico de tools (migrado da Fase 0, D1). O nome é a chave; o
  # factory devolve a tool (classe ou instância — RubyLLM aceita ambos).
  #   required (optional: false) -> sempre disponível, salvo deny.
  #   optional (optional: true)  -> só quando o agente faz opt-in via allow.
  class ToolRegistry
    Entry = Data.define(:name, :optional, :plugin, :factory)

    # Event stream nulo p/ o atalho deprecated (não participa da pipeline de
    # eventos).
    class NullEventStream
      def emit(_event) = nil
    end
    private_constant :NullEventStream

    def initialize
      @entries = {}
      @resolve_warned = false
    end

    def register(name, klass = nil, optional: false, plugin: nil, &block)
      name = name.to_s
      factory = block || -> { klass }
      @entries[name] = Entry.new(name: name, optional: optional, plugin: plugin, factory: factory)
      self
    end

    def names = @entries.keys

    # [Entry] — é o que o Executor passa como candidate_tools (doc 03 §4).
    def entries = @entries.values

    # DEPRECATED (doc 05 §8): delega ao Policy::Engine com a ToolAllowlist e
    # devolve INSTÂNCIAS (retorno compatível com a Fase 0). Completa o BACKLOG
    # "Policy Engine — parcial" sem quebrar chamadores.
    def resolve(profile)
      unless @resolve_warned
        warn "[DEPRECATION] ToolRegistry#resolve: use Policy::Engine#decide (doc 05 §8)"
        @resolve_warned = true
      end

      engine = Policy::Engine.new(
        policy_registry: { "tool_allowlist" => Policy::Builtin::ToolAllowlist.new },
        event_stream: NullEventStream.new
      )
      request = Policy::PolicyRequest.new(
        profile: profile.with(policies: ["tool_allowlist"]), # força a ToolAllowlist
        command: nil, context: nil, candidate_tools: entries, candidate_skills: []
      )
      engine.decide(request).allowed_tools.map { |entry| entry.factory.call }
    end
  end
end

# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    # Nível 2 do progressive disclosure: carrega o corpo completo do SKILL.md
    # sob demanda. Respeita a allowlist do agente (o modelo não carrega uma
    # skill que a política não expôs).
    #
    # Migrado da Fase 0 sem mudança de lógica — só o módulo AgentRuntime ->
    # Harness (doc 00 §4). `require "ruby_llm"` fica NESTE arquivo (herda de
    # RubyLLM::Tool), por isso ele NÃO entra em lib/harness.rb: o Executor o
    # carrega lazy dentro de create_chat (D9).
    class LoadSkill < RubyLLM::Tool
      description "Carrega as instruções completas (SKILL.md) de uma skill pelo nome"
      param :name, desc: "Nome exato da skill, conforme listado em <available_skills>"

      def initialize(catalog, allowed_names)
        @catalog = catalog
        @allowed = Array(allowed_names).map(&:to_s)
        super()
      end

      def execute(name:)
        return { error: "skill '#{name}' não disponível para este agente" } unless @allowed.include?(name.to_s)

        skill = @catalog.find(name)
        return { error: "skill '#{name}' não encontrada" } unless skill

        skill.body
      end
    end
  end
end

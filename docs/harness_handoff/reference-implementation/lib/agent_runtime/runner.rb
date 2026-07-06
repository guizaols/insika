# frozen_string_literal: true

require "ruby_llm"

module AgentRuntime
  # Cola de serviço. NÃO reimplementa o loop — isso é do RubyLLM. Resolve o
  # perfil do agente, aplica as políticas de tool/skill, monta o chat e
  # traduz callbacks -> fluxo de Events pra SSE. Núcleo stateless.
  class Runner
    def initialize(registry:, catalog:, system_prompt:, profiles:)
      @registry = registry
      @catalog = catalog
      @system_prompt = system_prompt
      @profiles = profiles
    end

    def run(agent_id, message, history: [], &emit)
      emit ||= ->(_event) {}
      profile = @profiles.fetch(agent_id.to_s) { raise ArgumentError, "agente '#{agent_id}' não configurado" }

      eff_skills = @catalog.effective(profile.skills)
      allowed_skill_names = eff_skills.map(&:name)

      chat = build_chat(profile, eff_skills, allowed_skill_names)
      seed_history(chat, history)
      wire_callbacks(chat, emit)

      response = chat.ask(message) do |chunk|
        emit.call(Event.new(:content, { delta: chunk.content })) if chunk.content
      end

      emit.call(Event.new(:done, { content: response.content }))
      response
    end

    private

    def build_chat(profile, eff_skills, allowed_skill_names)
      chat = RubyLLM.chat(
        model: profile.model,
        provider: profile.provider,
        assume_model_exists: !profile.provider.nil?
      )

      prompt = @system_prompt.build(
        skills_block: @catalog.format_for_prompt(eff_skills)
      )
      chat.with_instructions(prompt) unless prompt.empty?

      # load_skill é default de sistema (fora da allowlist), senão o
      # progressive disclosure quebra. Demais tools vêm do registry.
      tools = @registry.resolve(profile)
      tools << Tools::LoadSkill.new(@catalog, allowed_skill_names) unless allowed_skill_names.empty?
      chat.with_tools(*tools) unless tools.empty?

      chat
    end

    def seed_history(chat, history)
      history.each do |m|
        chat.add_message(role: m[:role].to_sym, content: m[:content])
      end
    end

    # Callbacks aditivos (v1.15+). load_skill vira :skill_activated.
    def wire_callbacks(chat, emit)
      chat.before_tool_call do |tool_call|
        if tool_call.name.to_s == "load_skill"
          args = tool_call.arguments || {}
          emit.call(Event.new(:skill_activated, { name: args["name"] || args[:name] }))
        else
          emit.call(Event.new(:tool_call, { name: tool_call.name, arguments: tool_call.arguments }))
        end
      end

      chat.after_tool_result do |result|
        emit.call(Event.new(:tool_result, { result: result.to_s }))
      end
    end
  end
end

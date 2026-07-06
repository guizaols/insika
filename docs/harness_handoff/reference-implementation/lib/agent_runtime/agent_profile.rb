# frozen_string_literal: true

module AgentRuntime
  # Configuração por agente (data-driven, não uma subclasse por tenant).
  # Semântica de allowlist idêntica à do OpenClaw.
  #
  # tools_allow: nil/[]  -> sem restrição (todas as required + optional opt-in)
  #              [names]  -> conjunto final (não faz merge com defaults)
  # tools_deny:  [names]  -> sempre removidas
  # skills:      nil      -> todas as skills
  #              []       -> nenhuma skill
  #              [names]  -> subconjunto (conjunto final)
  AgentProfile = Data.define(
    :id, :model, :provider, :base_prompt, :prompt_files,
    :tools_allow, :tools_deny, :skills
  ) do
    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills
      )
    end

    # opt-in de tool optional = estar na allow do agente.
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end

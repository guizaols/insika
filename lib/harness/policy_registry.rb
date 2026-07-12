# frozen_string_literal: true

module Harness
  # Registry de policies. `resolve(name) -> Policy::Base`.
  # As builtin (ToolAllowlist/SkillAllowlist/WorkflowAllowlist) são registradas
  # NO BOOT pelo composition root (config/wiring.rb), não aqui.
  #
  # NB: o Policy::Engine consome via `fetch(name)`; um Hash também
  # satisfaz esse duck-type. Este registry é a implementação de produção — para
  # usá-lo com o Engine, exponha `fetch` delegando a `resolve`.
  class PolicyRegistry < Registry
    # -> Policy::Base (INSTÂNCIA): o Engine chama #decide no resultado. Se a
    # policy foi registrada como CLASSE, instancia; se já veio instância/factory
    # que devolve instância, passa direto.
    def resolve(name)
      resolved = super
      resolved.is_a?(Class) ? resolved.new : resolved
    end

    # Alias do duck-type que o Policy::Engine espera (fetch(name) -> Policy::Base).
    def fetch(name) = resolve(name)
  end
end

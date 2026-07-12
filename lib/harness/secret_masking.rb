# frozen_string_literal: true

module Harness
  # Masking de segredos no round-trip UI↔Store (Fase 4 — Studio, D6). Padrão do
  # OpenClaw: um segredo NUNCA volta em plaintext pra tela — vira o sentinel
  # `__OCULTO__`. Ao gravar, o sentinel de volta significa "mantém o que já
  # estava"; uma string nova substitui; `""` limpa. Compartilhado por
  # llm_providers (api keys) e, futuramente, instâncias MCP (credenciais).
  module SecretMasking
    SENTINEL = "__OCULTO__"

    module_function

    # Valor a EXIBIR: presente -> sentinel (nunca o plaintext); ausente -> nil.
    def mask(value)
      present?(value) ? SENTINEL : nil
    end

    # Valor a PERSISTIR dado o que o form mandou (`incoming`) e o que já existia
    # (`existing`):
    #   - não enviado (nil) ......... preserva `existing`
    #   - sentinel `__OCULTO__` ..... preserva `existing`
    #   - "" (vazio) ................ limpa (nil)
    #   - string nova ............... substitui
    def reconcile(incoming, existing)
      return existing if incoming.nil? || incoming == SENTINEL

      s = incoming.to_s
      s.empty? ? nil : s
    end

    def present?(value)
      !(value.nil? || value.to_s.empty?)
    end
  end
end

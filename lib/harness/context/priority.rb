# frozen_string_literal: true

module Harness
  module Context
    # Escada de precedência dos fragmentos de contexto — FONTE ÚNICA da ordem
    # (Fase 6/D5, fronteira de confiança). Maior = mais autoridade: aparece antes
    # no system prompt e sobrevive a cortes de orçamento. Os providers referenciam
    # estas constantes em vez de números soltos, para que a fronteira seja um
    # contrato auditável num lugar só (o trust_boundary_spec trava a ordem).
    #
    # Contrato (NF3/D5): identidade e guardrails entram PINNED no topo; as
    # injeções de TURNO (request_context — tenant/vars do consumidor) ficam no
    # FUNDO e são sacrificadas PRIMEIRO sob orçamento. A identidade (pinned) NUNCA
    # é truncada. Um prompt-injection que suba por dados de turno é DADO, não
    # autoridade — não sobrepõe IDENTITY/SOUL, e decisões de segurança
    # (allow/deny de tool, egress, approvals) vivem no motor/profile, nunca no
    # bloco injetado.
    module Priority
      IDENTITY     = 100 # IDENTITY/SOUL (Prompt) — pinned
      PROMPT_REF   = 90  # guardrails/refs do Prompt Catalog (Prompt) — pinned
      SKILL        = 80  # <available_skills> nível 1 (Skill)
      MEMORY       = 75  # <memory> read path (Memory)
      TOOL_SEARCH  = 70  # <available_tools> nível 1 (ToolSearch)
      HISTORY_MAX  = 79  # teto do histórico por recência (Session)
      HISTORY_BASE = 60  # base do histórico; +idx até o teto (Session)
      REQUEST      = 40  # <request_context> — injeção de turno, a mais cortável
    end
  end
end

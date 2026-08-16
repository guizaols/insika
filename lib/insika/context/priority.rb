# frozen_string_literal: true

module Insika
  module Context
    # Precedence ladder for context fragments — SINGLE SOURCE of the order
    # (trust boundary). Higher = more authority: appears earlier
    # in the system prompt and survives budget cuts. Providers reference these
    # constants instead of loose numbers, so the boundary is an auditable
    # contract in a single place (trust_boundary_spec locks the order).
    #
    # Contract: identity and guardrails go PINNED at the top; TURN
    # injections (request_context — the consumer's tenant/vars) sit at the
    # BOTTOM and are sacrificed FIRST under budget. Identity (pinned) is NEVER
    # truncated. A prompt injection riding in via turn data is DATA, not
    # authority — it does not override IDENTITY/SOUL, and security decisions
    # (tool allow/deny, egress, approvals) live in the engine/profile, never in
    # the injected block.
    module Priority
      IDENTITY     = 100 # IDENTITY/SOUL (Prompt) — pinned
      PROMPT_REF   = 90  # Prompt Catalog guardrails/refs (Prompt) — pinned
      SKILL_BODY   = 85  # <active_skill> trigger-matched body (SkillTrigger)
      SKILL        = 80  # <available_skills> level 1 (Skill)
      MEMORY       = 75  # <memory> read path (Memory)
      TOOL_SEARCH  = 70  # <available_tools> level 1 (ToolSearch)
      BRIEFING     = 65  # <briefing> session working state (Briefing) — D5:
                         #   below every identity/skill/memory block (never breaks the
                         #   pinned prefix), above the turn's own <request_context>.
      HISTORY_MAX  = 79  # history ceiling by recency (Session)
      HISTORY_BASE = 60  # history base; +idx up to the ceiling (Session)
      REQUEST      = 40  # <request_context> — turn injection, the most cuttable
    end
  end
end

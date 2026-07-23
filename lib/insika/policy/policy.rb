# frozen_string_literal: true

module Insika
  module Policy
    # Stage 3 input. candidate_tools = [ToolRegistry::Entry]
    # (UNfiltered); candidate_skills = [SkillCatalog::Skill] from
    # catalog.effective(profile.skills). context = ContextPackage (Context before
    # Policy).
    PolicyRequest = Data.define(:profile, :command, :context,
                                :candidate_tools, :candidate_skills)

    # Output of ONE policy. allow_* == nil => "no restriction from this
    # policy" (does not enter the intersection); [] => empty set; deny_* is always
    # a list (union). verdict :deny denies the WHOLE TURN. All immutable Data — the
    # policy's purity is structural.
    # `requires_approval`: names of tools that require human approval —
    # does NOT deny or allow; the real gate is in the ToolEnvelope (stage 6). Default [].
    Decision = Data.define(:allow_tools, :deny_tools, :allow_skills, :deny_skills,
                           :requires_approval, :verdict, :reason) do
      def self.allow(allow_tools: nil, deny_tools: [], allow_skills: nil, deny_skills: [],
                     requires_approval: [])
        new(allow_tools: allow_tools, deny_tools: deny_tools, allow_skills: allow_skills,
            deny_skills: deny_skills, requires_approval: requires_approval,
            verdict: :allow, reason: nil)
      end

      def self.deny(reason:, allow_tools: nil, deny_tools: [], allow_skills: nil, deny_skills: [],
                    requires_approval: [])
        new(allow_tools: allow_tools, deny_tools: deny_tools, allow_skills: allow_skills,
            deny_skills: deny_skills, requires_approval: requires_approval,
            verdict: :deny, reason: reason)
      end
    end

    # Policy base class. PURE — no IO, no mutation; determinism
    # is required by the handoff.
    class Base
      def id = self.class.name

      def decide(_request)
        raise NotImplementedError, "#{self.class}#decide"
      end
    end

    # Builtin policies.
    module Builtin
      # Absorbs ToolRegistry#resolve as a policy: optional without
      # opt-in -> deny; tools_deny -> deny ("deny always wins"); tools_allow
      # with the semantics (nil = all; [] = ∅; [names] = final set).
      # Phase 7/D4/F5 (Step C): `tools_allow_groups` UNIONS in the groups' tools
      # (the group is GIVEN in the Entry metadata). Both allowlists nil = all.
      class ToolAllowlist < Base
        def decide(request)
          profile = request.profile
          # optional lives in the Entry metadata; candidate_tools are
          # ToolRegistry::Entry (Registry::Entry with metadata).
          deny = request.candidate_tools
                 .select { |e| e.metadata[:optional] && !profile.tool_opted_in?(e.name) }
                 .map { |e| e.name.to_s }
          deny += Array(profile.tools_deny).map(&:to_s)

          allow = allowed_names(profile, request.candidate_tools)
          Decision.allow(allow_tools: allow, deny_tools: deny.uniq)
        end

        private

        # nil = NO restriction (all) ONLY when tools_allow AND tools_allow_groups
        # are absent (parity). Otherwise it's the UNION: explicit names +
        # tools whose `group` (metadata) is in tools_allow_groups. An allow []
        # (with groups nil) still = ∅.
        def allowed_names(profile, candidates)
          names = profile.tools_allow.nil? ? nil : Array(profile.tools_allow).map(&:to_s)
          groups = profile.tools_allow_groups.nil? ? nil : Array(profile.tools_allow_groups).map(&:to_s)
          return nil if names.nil? && groups.nil?

          from_groups = Array(groups).empty? ? [] : candidates
                        .select { |e| groups.include?(e.metadata[:group].to_s) }
                        .map { |e| e.name.to_s }
          Array(names) | from_groups
        end
      end

      # nil/[]/[names] semantics of profile.skills. effective
      # stays in the catalog (query); the DECISION to use it is here.
      class SkillAllowlist < Base
        def decide(request)
          allow = request.profile.skills.nil? ? nil : Array(request.profile.skills).map(&:to_s)
          Decision.allow(allow_skills: allow)
        end
      end

      # Enforcement of the workflows_allow field. Neutral outside
      # :trigger_workflow; denies the turn when the workflow is not in the allowlist.
      class WorkflowAllowlist < Base
        def decide(request)
          command = request.command
          return Decision.allow if command.nil? || command.type != :trigger_workflow

          name = (command.payload[:workflow] || command.payload["workflow"]).to_s
          allow = request.profile.workflows_allow
          return Decision.allow if allow.nil? || Array(allow).map(&:to_s).include?(name)

          Decision.deny(reason: "workflow '#{name}' not in the allowlist of agent '#{request.profile.id}'")
        end
      end

      # Marks tools that require human approval. Does not deny/allow —
      # attaches `requires_approval` to the Resolution; the gate is in the ToolEnvelope
      # (stage 6), where the call happens. Allowlist semantics: nil = none; [names] =
      # those require approval. Pure/synchronous.
      class ApprovalRequired < Base
        def decide(request)
          names = request.profile.approvals_required
          Decision.allow(requires_approval: names.nil? ? [] : Array(names).map(&:to_s))
        end
      end
    end
  end
end

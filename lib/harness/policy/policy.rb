# frozen_string_literal: true

module Harness
  module Policy
    # Input do estágio 3. candidate_tools = [ToolRegistry::Entry]
    # (SEM filtrar); candidate_skills = [SkillCatalog::Skill] de
    # catalog.effective(profile.skills). context = ContextPackage (Context antes
    # de Policy).
    PolicyRequest = Data.define(:profile, :command, :context,
                                :candidate_tools, :candidate_skills)

    # Saída de UMA policy. allow_* == nil => "sem restrição desta
    # policy" (não entra na interseção); [] => conjunto vazio; deny_* é sempre
    # lista (união). verdict :deny nega o TURNO inteiro. Tudo Data imutável — a
    # pureza da policy é estrutural.
    # `requires_approval`: nomes de tools que exigem aprovação humana —
    # NÃO nega nem permite; o gate real é no ToolEnvelope (estágio 6). Default [].
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

    # Classe base de policy. PURA — sem IO, sem mutação; o
    # determinismo é exigido pelo handoff.
    class Base
      def id = self.class.name

      def decide(_request)
        raise NotImplementedError, "#{self.class}#decide"
      end
    end

    # Policies builtin.
    module Builtin
      # Absorve o ToolRegistry#resolve como policy: optional sem
      # opt-in -> deny; tools_deny -> deny ("deny sempre vence"); tools_allow
      # com a semântica (nil = todas; [] = ∅; [names] = conjunto final).
      class ToolAllowlist < Base
        def decide(request)
          profile = request.profile
          # optional vive no metadata da Entry; candidate_tools são
          # ToolRegistry::Entry (Registry::Entry com metadata).
          deny = request.candidate_tools
                 .select { |e| e.metadata[:optional] && !profile.tool_opted_in?(e.name) }
                 .map { |e| e.name.to_s }
          deny += Array(profile.tools_deny).map(&:to_s)

          allow = profile.tools_allow.nil? ? nil : Array(profile.tools_allow).map(&:to_s)
          Decision.allow(allow_tools: allow, deny_tools: deny.uniq)
        end
      end

      # Semântica nil/[]/[names] de profile.skills. effective
      # permanece no catálogo (consulta); a DECISÃO de usá-lo é aqui.
      class SkillAllowlist < Base
        def decide(request)
          allow = request.profile.skills.nil? ? nil : Array(request.profile.skills).map(&:to_s)
          Decision.allow(allow_skills: allow)
        end
      end

      # Enforcement do campo workflows_allow. Neutra fora de
      # :trigger_workflow; deny do turno quando o workflow não está na allowlist.
      class WorkflowAllowlist < Base
        def decide(request)
          command = request.command
          return Decision.allow if command.nil? || command.type != :trigger_workflow

          name = (command.payload[:workflow] || command.payload["workflow"]).to_s
          allow = request.profile.workflows_allow
          return Decision.allow if allow.nil? || Array(allow).map(&:to_s).include?(name)

          Decision.deny(reason: "workflow '#{name}' fora da allowlist do agente '#{request.profile.id}'")
        end
      end

      # Marca tools que exigem aprovação humana. Não nega/permite —
      # anexa `requires_approval` à Resolution; o gate é no ToolEnvelope (estágio
      # 6), onde a call ocorre. Semântica allowlist: nil = nenhuma; [names] =
      # essas exigem aprovação. Pura/síncrona.
      class ApprovalRequired < Base
        def decide(request)
          names = request.profile.approvals_required
          Decision.allow(requires_approval: names.nil? ? [] : Array(names).map(&:to_s))
        end
      end
    end
  end
end

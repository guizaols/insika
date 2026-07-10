# frozen_string_literal: true

module Harness
  module Policy
    # Input do estágio 3 (doc 05 §2). candidate_tools = [ToolRegistry::Entry]
    # (SEM filtrar); candidate_skills = [SkillCatalog::Skill] de
    # catalog.effective(profile.skills). context = ContextPackage (Context antes
    # de Policy, RFC-0002 §5).
    PolicyRequest = Data.define(:profile, :command, :context,
                                :candidate_tools, :candidate_skills)

    # Saída de UMA policy (doc 05 §2). allow_* == nil => "sem restrição desta
    # policy" (não entra na interseção); [] => conjunto vazio; deny_* é sempre
    # lista (união). verdict :deny nega o TURNO inteiro. Tudo Data imutável — a
    # pureza da policy é estrutural (doc 05 §3).
    Decision = Data.define(:allow_tools, :deny_tools, :allow_skills, :deny_skills,
                           :verdict, :reason) do
      def self.allow(allow_tools: nil, deny_tools: [], allow_skills: nil, deny_skills: [])
        new(allow_tools: allow_tools, deny_tools: deny_tools, allow_skills: allow_skills,
            deny_skills: deny_skills, verdict: :allow, reason: nil)
      end

      def self.deny(reason:, allow_tools: nil, deny_tools: [], allow_skills: nil, deny_skills: [])
        new(allow_tools: allow_tools, deny_tools: deny_tools, allow_skills: allow_skills,
            deny_skills: deny_skills, verdict: :deny, reason: reason)
      end
    end

    # Classe base de policy. PURA — sem IO, sem mutação (doc 05 §1, L1); o
    # determinismo é exigido pelo handoff §6.
    class Base
      def id = self.class.name

      def decide(_request)
        raise NotImplementedError, "#{self.class}#decide"
      end
    end

    # Policies builtin da Fase 1 (doc 05 §2).
    module Builtin
      # Absorve o ToolRegistry#resolve da Fase 0 como policy (L4): optional sem
      # opt-in -> deny; tools_deny -> deny ("deny sempre vence"); tools_allow
      # com semântica D6 (nil = todas; [] = ∅; [names] = conjunto final).
      class ToolAllowlist < Base
        def decide(request)
          profile = request.profile
          deny = request.candidate_tools
                 .select { |e| e.optional && !profile.tool_opted_in?(e.name) }
                 .map { |e| e.name.to_s }
          deny += Array(profile.tools_deny).map(&:to_s)

          allow = profile.tools_allow.nil? ? nil : Array(profile.tools_allow).map(&:to_s)
          Decision.allow(allow_tools: allow, deny_tools: deny.uniq)
        end
      end

      # Semântica nil/[]/[names] de profile.skills (doc 05 §2). effective
      # permanece no catálogo (consulta); a DECISÃO de usá-lo é aqui (doc 05 §8).
      class SkillAllowlist < Base
        def decide(request)
          allow = request.profile.skills.nil? ? nil : Array(request.profile.skills).map(&:to_s)
          Decision.allow(allow_skills: allow)
        end
      end

      # Enforcement do campo workflows_allow (D6). Neutra fora de
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
    end
  end
end

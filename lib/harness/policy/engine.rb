# frozen_string_literal: true

require "time"

module Harness
  module Policy
    # Estágio 3 da pipeline (doc 05 §2-§3). Agrega as policies do perfil na
    # ordem declarada: interseção de allows não-nil, união de denies (L3 —
    # comutativa, empate impossível por construção). Fail-closed (L2): crash ou
    # nome não registrado vira deny. Roda INLINE no fiber (puras, sem IO — sem
    # Async, sem timeout próprio, doc 05 §5).
    class Engine
      Resolution = Data.define(:allowed_tools, :allowed_skills, :audit)

      def initialize(policy_registry:, event_stream:)
        @registry = policy_registry # duck-type: fetch(name)
        @event_stream = event_stream
      end

      # -> Resolution | raise PolicyDenied
      def decide(request)
        audit = []
        allow_tool_sets = []
        deny_tools = []
        allow_skill_sets = []
        deny_skills = []

        Array(request.profile.policies).each do |name|
          decision = evaluate(name, request)
          audit << { policy: name.to_s, verdict: decision.verdict, reason: decision.reason }

          deny_turn!(name, decision.reason, audit) if decision.verdict == :deny

          allow_tool_sets << decision.allow_tools.map(&:to_s) unless decision.allow_tools.nil?
          deny_tools.concat(Array(decision.deny_tools).map(&:to_s))
          allow_skill_sets << decision.allow_skills.map(&:to_s) unless decision.allow_skills.nil?
          deny_skills.concat(Array(decision.deny_skills).map(&:to_s))
        end

        Resolution.new(
          allowed_tools: filter(request.candidate_tools, allow_tool_sets, deny_tools) { |e| e.name.to_s },
          allowed_skills: filter(request.candidate_skills, allow_skill_sets, deny_skills) { |s| s.name.to_s },
          audit: audit
        )
      end

      private

      # Fail-closed (L2): qualquer exceção (bug da policy OU nome não registrado)
      # vira deny — NUNCA fail-open.
      def evaluate(name, request)
        policy = @registry.fetch(name)
        raise "policy não registrada: #{name}" if policy.nil?

        policy.decide(request)
      rescue StandardError => e
        Decision.deny(reason: "policy crash: #{e.class}")
      end

      # Primeiro deny reporta (evento + PolicyDenied) e interrompe: as policies
      # seguintes nem rodam, mas o audit registra até aqui.
      def deny_turn!(policy_name, reason, _audit)
        @event_stream.emit(Harness::Event.new(
                             type: :policy_denied,
                             data: { policy: policy_name.to_s, reason: reason },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        raise Harness::PolicyDenied.new(policy: policy_name.to_s, reason: reason)
      end

      # nomes_permitidos = nomes(candidatas) ∩ (∩ allows não-nil) − (∪ denies).
      def filter(candidates, allow_sets, deny_names)
        allowed = candidates.map { |c| yield(c) }
        allow_sets.each { |set| allowed &= set }
        allowed -= deny_names
        candidates.select { |c| allowed.include?(yield(c)) }
      end
    end
  end
end

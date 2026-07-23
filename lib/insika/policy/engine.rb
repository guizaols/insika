# frozen_string_literal: true

require "time"

module Insika
  module Policy
    # Pipeline stage 3. Aggregates the profile's policies in the
    # declared order: intersection of non-nil allows, union of denies
    # (commutative, ties impossible by construction). Fail-closed: a crash or
    # an unregistered name becomes a deny. Runs INLINE on the fiber (pure, no IO — no
    # Async, no timeout of its own).
    class Engine
      Resolution = Data.define(:allowed_tools, :allowed_skills, :requires_approval, :audit)

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
        requires_approval = []

        Array(request.profile.policies).each do |name|
          decision = evaluate(name, request)
          audit << { policy: name.to_s, verdict: decision.verdict, reason: decision.reason }

          deny_turn!(name, decision.reason, audit) if decision.verdict == :deny

          allow_tool_sets << decision.allow_tools.map(&:to_s) unless decision.allow_tools.nil?
          deny_tools.concat(Array(decision.deny_tools).map(&:to_s))
          allow_skill_sets << decision.allow_skills.map(&:to_s) unless decision.allow_skills.nil?
          deny_skills.concat(Array(decision.deny_skills).map(&:to_s))
          requires_approval.concat(Array(decision.requires_approval).map(&:to_s))
        end

        Resolution.new(
          allowed_tools: filter(request.candidate_tools, allow_tool_sets, deny_tools) { |e| e.name.to_s },
          allowed_skills: filter(request.candidate_skills, allow_skill_sets, deny_skills) { |s| s.name.to_s },
          requires_approval: requires_approval.uniq,
          audit: audit
        )
      end

      private

      # Fail-closed: any exception (policy bug OR unregistered name)
      # becomes a deny — NEVER fail-open.
      def evaluate(name, request)
        policy = @registry.fetch(name)
        raise "policy not registered: #{name}" if policy.nil?

        policy.decide(request)
      rescue StandardError => e
        Decision.deny(reason: "policy crash: #{e.class}")
      end

      # The first deny reports (event + PolicyDenied) and halts: the following
      # policies don't even run, but the audit records up to here.
      def deny_turn!(policy_name, reason, _audit)
        @event_stream.emit(Insika::Event.new(
                             type: :policy_denied,
                             data: { policy: policy_name.to_s, reason: reason },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        raise Insika::PolicyDenied.new(policy: policy_name.to_s, reason: reason)
      end

      # allowed_names = names(candidates) ∩ (∩ non-nil allows) − (∪ denies).
      def filter(candidates, allow_sets, deny_names)
        allowed = candidates.map { |c| yield(c) }
        allow_sets.each { |set| allowed &= set }
        allowed -= deny_names
        candidates.select { |c| allowed.include?(yield(c)) }
      end
    end
  end
end

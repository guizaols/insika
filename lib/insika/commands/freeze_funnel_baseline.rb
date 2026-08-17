# frozen_string_literal: true

require "time"
require "date"

module Insika
  module Commands
    # RFC-0032 C5: the operator's FREEZE — turn the folded counts over a
    # declared span into the baseline snapshot RFC-0033 (A/B follow-up) and
    # RFC-0035 (promotion gate) read. One command, dispatched from the Studio
    # and available to any operator-grade caller. Synchronous control command —
    # no task, no actor, same discipline as RecordOutcome (WS7).
    #
    # The ≥ 4-week rule (RFC §4.4 — "no 1.0 target before a remeasure") is
    # enforced HERE, not by convention: a frozen span shorter than 28 days is a
    # ValidationError. `frozen_at` stamps when; the baseline OVERWRITES (D5) —
    # the freeze event is the audit surface.
    class FreezeFunnelBaseline
      MIN_SPAN_DAYS = 28

      def initialize(funnel_store:, profiles:, event_stream:)
        @funnel_store = funnel_store
        @profiles = profiles
        @event_stream = event_stream
      end

      # payload: { agent:, tenant:, from: "YYYY-MM-DD", to: "YYYY-MM-DD", operator: }
      #   agent REQUIRED (ValidationError); tenant from payload || meta[:tenant].
      #   from/to optional — default to the pair's folded span (first/last day
      #   cell); explicit from/to are inclusive bounds.
      # -> the baseline record.
      def call(command)
        payload = command.payload
        agent = Coercion.presence(payload[:agent] || payload["agent"])
        raise ValidationError, "agent is required" if agent.nil?

        declaration = declaration_for(agent)
        tenant = payload[:tenant] || payload["tenant"] || command.meta[:tenant]

        from, to = bounds(payload, tenant, agent)
        validate_span!(from, to)

        stages = @funnel_store.days(tenant: tenant, agent: agent, from: from, to: to)
                              .each_with_object(Hash.new(0)) do |(_, counts), acc|
          counts.each { |stage, n| acc[stage] += n }
        end
        primary = declaration.primary
        primary_count = stages[primary].to_i
        first_count = stages[declaration.first_stage].to_i
        conversion = first_count.zero? ? nil : primary_count.to_f / first_count

        baseline = {
          "from" => from, "to" => to, "stages" => stages,
          "primary" => primary, "primary_count" => primary_count,
          "conversion" => conversion, "window" => declaration.attribution_window,
          "frozen_at" => Time.now.utc.iso8601
        }
        @funnel_store.set_baseline(tenant: tenant, agent: agent, record: baseline)

        @event_stream.emit(Insika::Event.new(
                             type: :funnel_baseline_frozen,
                             data: { agent: agent, from: from, to: to,
                                     primary: primary, primary_count: primary_count,
                                     conversion: conversion },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        baseline
      end

      private

      # -> FunnelDeclaration | raise — the freeze needs the parsed declaration,
      # so a malformed/absent one is a hard ValidationError (D8: the FOLD skips
      # malformed declarations, but freezing without one is an operator error).
      def declaration_for(agent)
        profile = @profiles.fetch(agent)
        decl = profile && Insika::FunnelDeclaration.parse(profile.funnel)
        return decl if decl

        raise ValidationError, "agent '#{agent}' has no valid funnel declaration"
      end

      # Explicit from/to (inclusive) or the pair's folded span (first/last day
      # cell). -> [String, String].
      def bounds(payload, tenant, agent)
        from = Coercion.presence(payload[:from] || payload["from"])
        to = Coercion.presence(payload[:to] || payload["to"])
        # both given -> no scan at all (a pair with no cells still freezes,
        # over a zero-count span, when the operator names the dates)
        return [from, to] if from && to

        days = @funnel_store.days(tenant: tenant, agent: agent)
        days_keys = days.keys
        raise ValidationError, "no folded days for agent '#{agent}'" if days_keys.empty?

        [from || days_keys.first, to || days_keys.last]
      end

      def validate_span!(from, to)
        raise ValidationError, "from must be before to" if from >= to

        span = (Date.iso8601(to) - Date.iso8601(from)).to_i
        if span < MIN_SPAN_DAYS
          raise ValidationError,
                "baseline span must cover at least #{MIN_SPAN_DAYS} days " \
                "(the RFC-0033/0035 number needs a remeasured baseline)"
        end
      rescue Date::Error
        raise ValidationError, "from/to must be ISO dates (YYYY-MM-DD)"
      end
    end
  end
end
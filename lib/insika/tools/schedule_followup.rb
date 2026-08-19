# frozen_string_literal: true

require "ruby_llm"
require "time"

module Insika
  module Tools
    # `schedule` — the agent books a follow-up with a customer at
    # a future time. The tool ONLY validates shape + the dedup rule (D6/D7):
    # everything that can block (contact state, frequency, quiet hours, a
    # malformed policy) is decided at FIRE time by the policy in force then —
    # the schedule is a promise made in-conversation. The consent record IS
    # the tool call itself: the customer agreeing in-conversation writes
    # :granted.
    #
    # System builtin (like remember): `require "ruby_llm"` stays in THIS file,
    # loaded lazily by the Executor in create_chat. Never enveloped.
    class ScheduleFollowup < RubyLLM::Tool
      description "Schedule a follow-up with this customer at a future time. Use " \
                  "when the customer agrees to be contacted again (a product, a " \
                  "cart, a pending payment). The cancellation policy is permanent: " \
                  "a customer who opted out can never be rescheduled."
      param :at, desc: "ISO 8601 (absolute) or relative '+6h' / '+2d'"
      param :reason, desc: "Short machine-readable reason, e.g. 'pix pending, " \
                           "customer said she would pay tonight'"

      def name = "schedule"

      def initialize(contact_store:, followup_store:, state:, event_stream: nil, **)
        @contact_store = contact_store
        @followup_store = followup_store
        @state = state
        @event_stream = event_stream
        super()
      end

      def execute(at:, reason:)
        followup = @state.profile.followup
        # D9: a malformed policy is a tool error naming the rule (the
        # ValidationError rescue below).
        Insika::FollowupPolicy.parse!(followup)

        resolved = resolve_at(at)
        return { error: resolved } if resolved.is_a?(String)

        reason = reason.to_s.strip
        return { error: "reason is required (1..200 chars)" } if reason.empty? || reason.length > 200

        at_time = resolved
        return { error: "the follow-up must be at least 5 minutes in the future" } if at_time < Time.now.utc + 300

        tenant = @state.respond_to?(:tenant) ? @state.tenant : nil
        # D7: the tool call IS the consent — recorded WITHOUT un-silencing a
        # silent customer (only a customer message reopens, D2). A revoked
        # customer raises (the error names the opt-out).
        @contact_store.consent(tenant: tenant, customer: customer)
        record = @followup_store.create(
          tenant: tenant, agent: @state.profile.id, customer: customer,
          session_id: @state.task&.session_id, at: at_time, reason: reason,
          arm: arm(followup), transport: transport
        )
        emit(record.id, record.at)
        { scheduled: record.id, at: record.at, reason: record.reason }
      rescue Insika::ValidationError => e
        { error: e.message }
      end

      private

      # The customer is the SAME string the message contract carries — from
      # the running task's command, never from the model's arguments.
      def customer
        command = @state.task&.command
        return nil unless command.is_a?(Hash)

        payload = command["payload"] || command[:payload] || {}
        payload["customer"] || payload[:customer]
      end

      def arm(followup)
        return Insika::FollowupPolicy::DEFAULT_ARM unless followup.is_a?(Hash)

        arm = followup["arm"].to_s
        arm.empty? ? Insika::FollowupPolicy::DEFAULT_ARM : arm
      end

      # The transport is provenance captured at schedule time (D5): the fired
      # turn's reply travels out of band through the SAME channel.
      def transport
        command = @state.task&.command
        return nil unless command.is_a?(Hash)

        meta = command["meta"] || command[:meta] || {}
        meta["transport"] || meta[:transport]
      end

      # ISO-8601 UTC or `+(\d+)([mhd])+` relative forms; anything else is a
      # tool error. -> Time | String (the error).
      def resolve_at(raw)
        text = raw.to_s.strip
        if (m = text.match(/\A\+(\d+)([mhd])\z/))
          seconds = m[1].to_i * { "m" => 60, "h" => 3600, "d" => 86_400 }.fetch(m[2])
          return Time.now.utc + seconds
        end
        begin
          Time.iso8601(text).utc
        rescue ArgumentError
          return "`at` must be ISO 8601 (absolute) or relative '+6h' / '+2d'"
        end
      end

      # :followup_scheduled carries ids + at, NEVER the reason text — a reason
      # is contact data that rides the record and the Studio, not the events.
      def emit(id, at)
        @event_stream&.emit(Insika::Event.new(
                              type: :followup_scheduled,
                              data: { id: id, at: at },
                              meta: { task_id: @state.task&.id, session_id: @state.task&.session_id }
                            ))
      end
    end

    # `cancel_followup` — the sibling of `schedule`. Refuses a
    # record that is already fired (":fired — it is in the air; it fires
    # once"), refuses a record of another tenant (WS1), and is an idempotent
    # no-op for an already-cancelled one.
    class CancelFollowup < RubyLLM::Tool
      description "Cancel a previously scheduled follow-up by its id. A follow-up " \
                  "that already fired cannot be cancelled."
      param :id, desc: "The id returned by the schedule tool"

      def name = "cancel_followup"

      def initialize(followup_store:, state:, **)
        @followup_store = followup_store
        @state = state
        super()
      end

      def execute(id:)
        record = @followup_store.find(id.to_s)
        return { error: "no follow-up with id #{id}" } if record.nil?
        if record.status == "fired"
          return { error: "follow-up #{id} is already fired — it is in the air; it fires once" }
        end
        if record.status == "blocked"
          return { error: "follow-up #{id} is already blocked (#{record.blocked_reason})" }
        end

        tenant = (@state.respond_to?(:tenant) ? @state.tenant : nil).to_s
        unless record.tenant == (tenant.empty? ? "platform" : tenant)
          return { error: "follow-up #{id} belongs to another tenant" }
        end

        return { cancelled: record.id } if record.status == "cancelled" # idempotent

        @followup_store.cancel(id: record.id)
        { cancelled: record.id }
      rescue Insika::ValidationError => e
        { error: e.message }
      end
    end
  end
end

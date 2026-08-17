# frozen_string_literal: true

module Insika
  module Commands
    # RFC-0034 C6: the human's answer (RFC §4.4): approve (→ the RFC-0031
    # store, CAS, provenance `distilled:<session_ref>`), reject (with an
    # optional reason), dismiss (latches the tuple). Approval never silently
    # overwrites an operator edit (D5/E3): the CAS baseline captured at distill
    # time guards the write, and a lost race flips the proposal to `:stale`
    # carrying the fact's CURRENT value — both values visible on the wiki.
    # Synchronous control command — the Studio dispatches it; no task, no actor.
    class ResolveProposal
      DECISIONS = %w[approved rejected dismissed].freeze

      def initialize(proposal_store:, memory_store:, event_stream:)
        @proposal_store = proposal_store
        @memory_store = memory_store
        @event_stream = event_stream
      end

      # payload: { proposal_id:, decision: "approved"|"rejected"|"dismissed",
      #            operator?, note? }
      # operator from payload || command.meta[:operator] || "operator"
      # -> Proposal (the resolved record; a :stale one carries current_value)
      def call(command)
        proposal_id = Coercion.presence(command.payload[:proposal_id] || command.payload["proposal_id"])
        raise ValidationError, "proposal_id is required" if proposal_id.nil?

        decision = Coercion.presence(command.payload[:decision] || command.payload["decision"])
        raise ValidationError, "decision is required" unless DECISIONS.include?(decision)

        proposal = @proposal_store.find(proposal_id)
        raise Insika::NotFoundError, "proposal not found: #{proposal_id}" if proposal.nil?

        operator = operator_for(command)
        note = Coercion.presence(command.payload[:note] || command.payload["note"])

        case decision
        when "approved" then approve(command, proposal, operator, note)
        when "rejected"
          resolved = @proposal_store.reject(id: proposal.id, operator: operator, note: note)
          emit(:proposal_rejected, resolved)
          resolved
        else # "dismissed"
          resolved = @proposal_store.dismiss(id: proposal.id, operator: operator, note: note)
          emit(:proposal_dismissed, resolved)
          resolved
        end
      end

      private

      # The whole safety argument (D5/E3). The read-check-write CAS rides the
      # store's transaction — a lost race is a re-present, never a silent
      # overwrite.
      def approve(command, proposal, operator, note)
        fact = @memory_store.get_fact(tenant: proposal.tenant, customer: proposal.customer,
                                      key: proposal.key)
        if proposal.expected_existed
          if fact && fact.updated_at == proposal.expected_revision
            written = @memory_store.replace_if_revision(
              tenant: proposal.tenant, customer: proposal.customer,
              key: proposal.key, value: proposal.value,
              expected_revision: proposal.expected_revision,
              origin: "distilled:#{proposal.session_ref}")
            return stale(proposal, fact, operator) unless written
          else
            return stale(proposal, fact, operator) # the operator's edit stands
          end
        elsif fact
          return stale(proposal, fact, operator) # the operator created it first
        else
          @memory_store.put_fact(tenant: proposal.tenant, customer: proposal.customer,
                                 key: proposal.key, value: proposal.value,
                                 origin: "distilled:#{proposal.session_ref}")
        end
        resolved = @proposal_store.approve(id: proposal.id, operator: operator, note: note)
        emit(:proposal_approved, resolved)
        resolved
      end

      # The re-present (E3): the proposal carries the fact's CURRENT value next
      # to the proposed one; both are visible on the wiki page.
      def stale(proposal, fact, operator)
        resolved = @proposal_store.mark_stale(id: proposal.id, current_value: fact&.value,
                                              operator: operator)
        emit(:proposal_stale, resolved)
        resolved
      end

      # ids and statuses only (D7) — a fact value never enters the stream.
      def emit(type, proposal)
        @event_stream.emit(Insika::Event.new(
                             type: type,
                             data: { proposal_id: proposal.id, status: proposal.status,
                                     operator: proposal.operator },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      def operator_for(command)
        Coercion.presence(command.payload[:operator] || command.payload["operator"]) ||
          Coercion.presence(command.meta[:operator]) ||
          "operator"
      end
    end
  end
end
# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: loads a SNAPSHOT into a conversation before its first
    # turn — the precondition an eval case starts from ("the customer already saw
    # three products", "a stored preference"), without replaying the turns that
    # would have produced it. Creates the session when it does not exist yet, then
    # writes the four kinds of state a turn reads:
    #
    #   history:  [{ role:, content: }] -> the transcript, stamped `origin: engine`
    #             (nobody typed these; a report must not read them as the customer)
    #   evidence: { ids: [] }              -> the session evidence ledger
    #   memory:   { facts: {}, notes: [] } -> the memory cell THIS turn will read
    #   briefing: { fields: {} }           -> the session briefing
    #
    # Refuses a session that already has messages (ConflictError -> 409): seeding a
    # used conversation is a test bug, not a merge — the case would assert against a
    # state nobody wrote down. Synchronous; does not create a Task. -> Session.
    class SeedSession
      def initialize(session_store:, memory_store:, event_stream:)
        @session_store = session_store
        @memory_store = memory_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        id = AgentPayload.presence(p[:id])
        raise Insika::ValidationError, "id is required" if id.nil?

        state = Coercion.deep_stringify(p[:state] || {})
        raise Insika::ValidationError, "state must be a Hash" unless state.is_a?(Hash)

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        customer = AgentPayload.presence(p[:customer])

        session = @session_store.find(id) || @session_store.create(id: id, vars: {})
        unless session.messages.empty?
          raise Insika::ConflictError,
                "session #{id} already has #{session.messages.size} message(s) — seed a fresh conversation"
        end

        seed_history(id, state["history"])
        seed_evidence(id, state["evidence"])
        seed_memory(memory_scope(tenant, customer, id), state["memory"])
        seed_briefing(id, state["briefing"])

        @event_stream.emit(Insika::Event.new(
                             type: :session_seeded,
                             data: { session_id: id, tenant: tenant, keys: state.keys }.compact,
                             meta: { session_id: id, at: Time.now.utc.iso8601 }
                           ))
        @session_store.find(id)
      end

      private

      def seed_history(id, history)
        return if history.nil?
        raise Insika::ValidationError, "state.history must be an array" unless history.is_a?(Array)

        messages = history.map do |m|
          raise Insika::ValidationError, "state.history entries must be { role:, content: }" unless m.is_a?(Hash)

          role = m["role"].to_s
          unless %w[user assistant].include?(role)
            raise Insika::ValidationError, "state.history role must be user or assistant (got #{role.inspect})"
          end

          { "role" => role, "content" => m["content"].to_s, "origin" => Insika::MessageOrigin::ENGINE }
        end
        @session_store.append_messages(id, messages) unless messages.empty?
      end

      def seed_evidence(id, evidence)
        return if evidence.nil?
        raise Insika::ValidationError, "state.evidence must be { ids: [] }" unless evidence.is_a?(Hash)

        ids = Array(evidence["ids"]).map(&:to_s).reject(&:empty?)
        @session_store.append_evidence(id, ids: ids, ungrounded: 0) unless ids.empty?
      end

      def seed_memory(scope, memory)
        return if memory.nil?
        raise Insika::ValidationError, "state.memory must be { facts: {}, notes: [] }" unless memory.is_a?(Hash)

        facts = memory["facts"] || {}
        raise Insika::ValidationError, "state.memory.facts must be a Hash" unless facts.is_a?(Hash)

        facts.each { |key, value| @memory_store.put_fact(tenant: scope, key: key, value: value, origin: "operator") }
        Array(memory["notes"]).each { |text| @memory_store.add_note(tenant: scope, text: text.to_s) }
      end

      def seed_briefing(id, briefing)
        return if briefing.nil?
        raise Insika::ValidationError, "state.briefing must be { fields: {} }" unless briefing.is_a?(Hash)

        fields = briefing["fields"] || {}
        raise Insika::ValidationError, "state.briefing.fields must be a Hash" unless fields.is_a?(Hash)

        fields.each { |field, value| @session_store.update_briefing(id, field: field, value: value) }
      end

      # The SAME cell the turn will read (the Executor's memory scope rule): a
      # customer -> "[tenant:]customer"; no customer -> the tenant's cell, or the
      # marked per-session cell "chat:<id>" when there is no tenant either. Seeding
      # any other cell would pass the case against a memory the model never sees.
      def memory_scope(tenant, customer, session_id)
        return [tenant, customer].compact.join(":") if customer

        tenant || "#{MemoryStore::SESSION_TAG}:#{session_id}"
      end
    end
  end
end

# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # What the two confirmation tools share: finding the customer's hold and
    # refusing anyone else's — another conversation's, the operator's, or one
    # already decided. Errors go back to the MODEL as bodies, never as
    # exceptions: a tool exception never ends the turn.
    module Confirmation
      CUSTOMER = PendingActionStore::CUSTOMER

      module_function

      # -> [PendingAction, nil] | [nil, String]
      def open_hold(state, pending_id)
        store = state.pending_action_store
        pending = store&.find(pending_id.to_s)
        return [nil, "no held action with pending_id #{pending_id}"] if pending.nil?
        return [nil, "#{pending_id} is not a customer confirmation"] unless pending.kind == CUSTOMER
        return [nil, "#{pending_id} belongs to another conversation"] unless pending.session_id.to_s == state.task.session_id.to_s
        # The hold and the answer to it are two customer messages, which is two
        # TASKS. A hold THIS task created has not been put to the customer yet —
        # the reply carrying it has not even been sent. Deciding it here would be
        # the model confirming itself, and the write would land with nobody's word
        # behind it.
        return [nil, "#{pending_id} was held on this same turn; the customer has not answered it yet"] if pending.task_id.to_s == state.task.id.to_s
        return [nil, "#{pending_id} was already #{pending.status}"] unless pending.status == :pending

        [pending, nil]
      end

      # The turn's enveloped instance of the held tool — the same wrapper the
      # hold came from, so the confirmed run pays every check but the hold.
      def held_tool(state, name)
        Array(state.allowed_tools).find do |tool|
          tool.respond_to?(:call_confirmed) &&
            (tool.name.to_s == name || (tool.respond_to?(:impl_name) && tool.impl_name.to_s == name))
        end
      end

      def emit(event_stream, state, type, pending)
        event_stream&.emit(Insika::Event.new(
                             type: type,
                             data: { pending_id: pending.id, tool: pending.tool },
                             meta: { task_id: state.task.id, session_id: state.task.session_id }
                           ))
      end
    end

    # Runs an action the engine held for the customer's confirmation. The
    # decision is written FIRST (durable — a crash between the two re-executes
    # the turn and finds it approved), the original tool runs SECOND through its
    # own envelope with the arguments recorded at the hold: there is no path to
    # confirm different arguments than the ones the customer was shown.
    # System builtin (like remember): `require "ruby_llm"` stays in THIS file,
    # loaded lazily by the Executor in create_chat.
    class ConfirmPending < RubyLLM::Tool
      description "Runs an action the customer has just confirmed. Call it only when the customer's " \
                  "message agrees to exactly what was proposed; a change, a question or a new request " \
                  "is cancel_pending instead."
      parameter :pending_id, description: "The pending_id the held action returned"

      def name = "confirm_pending"

      def initialize(event_stream:, state:)
        @event_stream = event_stream
        @state = state
        super()
      end

      def execute(pending_id:)
        pending, error = Confirmation.open_hold(@state, pending_id)
        return { error: error } if error

        tool = Confirmation.held_tool(@state, pending.tool)
        return { error: "#{pending.tool} is not available on this turn" } unless tool

        @state.pending_action_store.resolve(pending.id, decision: :approved, operator: Confirmation::CUSTOMER)
        Confirmation.emit(@event_stream, @state, :confirmation_confirmed, pending)
        tool.call_confirmed(pending.args || {})
      end
    end

    # Drops a held action: the customer declined, changed something, or asked
    # for anything else. The hold would expire on its own at the end of this
    # turn; cancelling says so now, and lets the model answer accordingly.
    class CancelPending < RubyLLM::Tool
      description "Drops an action that was waiting for the customer's confirmation, because they " \
                  "declined, changed something, or asked for something else."
      parameter :pending_id, description: "The pending_id the held action returned"

      def name = "cancel_pending"

      def initialize(event_stream:, state:)
        @event_stream = event_stream
        @state = state
        super()
      end

      def execute(pending_id:)
        pending, error = Confirmation.open_hold(@state, pending_id)
        return { error: error } if error

        @state.pending_action_store.resolve(pending.id, decision: :rejected, operator: Confirmation::CUSTOMER)
        Confirmation.emit(@event_stream, @state, :confirmation_cancelled, pending)
        { "status" => "cancelled", "tool" => pending.tool }
      end
    end
  end
end

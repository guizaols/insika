# frozen_string_literal: true

require "json"

module Insika
  module Context
    module Providers
      # The read path of a customer confirmation: the calls the envelope held on
      # an earlier turn of this session, rendered at the TAIL of the context —
      # right before the message that answers them — so the last thing the model
      # reads before replying is the question the customer is replying to. Zero
      # bytes when nothing is open, which is every turn of most conversations.
      class PendingConfirmation < ContextProvider
        def initialize(pending_action_store:)
          @store = pending_action_store
        end

        def id = "pending_confirmation"

        # Pack-declared: no customer_confirm -> no provider.
        def enabled_for?(profile)
          list = profile.respond_to?(:customer_confirm) ? profile.customer_confirm : nil
          !Array(list).empty?
        end

        def allowlisted? = false # `customer_confirm` is the opt-in, not the allowlist

        def call(request)
          session = request.respond_to?(:session) ? request.session : nil
          return [] if session.nil? || @store.nil?

          open = @store.open_for_session(session.id, kind: PendingActionStore::CUSTOMER)
          return [] if open.empty?

          [ContextFragment.build(content: render(open), placement: :tail, pinned: true,
                                 priority: Context::Priority::PENDING_CONFIRMATION, source: id)]
        end

        private

        def render(open)
          lines = open.map { |pa| "- #{pa.tool} #{JSON.generate(pa.args || {})} — pending_id #{pa.id}" }
          "## Awaiting the customer's confirmation\n#{lines.join("\n")}\n" \
            "Call confirm_pending only if the customer's message agrees to exactly this. " \
            "Anything else — a change, a question, a new request — is cancel_pending."
        end
      end
    end
  end
end

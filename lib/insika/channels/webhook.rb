# frozen_string_literal: true

require "json"

module Insika
  module Channels
    # A webhook as a Shape B "channel": the recipient of operator ALERTS
    # (WS6). One instance per configured URL, registered in the ChannelRegistry
    # so ChannelDelivery's outbox+claim+retry pipeline delivers the alert the
    # same way it delivers a chat answer — at-most-once, bounded retry, boot
    # sweep. Deliberately NOT Slack/CRM/anything: it POSTs the event as JSON and
    # the consumer interprets it (the engine transports, it does not integrate).
    class Webhook
      def initialize(url, http:)
        @http = http
      end

      # The ChannelDelivery contract: -> HTTP status (200..299 = delivered).
      # Every failure becomes a DeliveryError so the bounded retry records it.
      def deliver(payload, to:, delivery_id: nil)
        result = @http.request(
          method: :post, url: to,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(payload)
        )
        result[:status].to_i
      rescue StandardError => e
        raise Insika::DeliveryError, "webhook: #{e.message}"
      end
    end
  end
end
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
    #
    # The target URL is operator configuration, so the POST crosses the SAME
    # egress guard the Relay applies: https-only (fails closed), private/
    # loopback/metadata targets and DNS-rebindable hosts blocked. Without it the
    # `alerts.webhook` URL is an SSRF vector — a URL pointed at cloud metadata
    # or an internal API exfiltrates alert events out of the boundary (WS6).
    class Webhook
      def initialize(url, http:, allow_http: false, allow_private: false)
        @http = http
        @allow_http = allow_http
        @allow_private = allow_private
      end

      # The ChannelDelivery contract: -> HTTP status (200..299 = delivered).
      # Every failure becomes a DeliveryError so the bounded retry records it.
      def deliver(payload, to:, delivery_id: nil)
        if (reason = egress_violation(to))
          raise Insika::DeliveryError, "webhook egress blocked for #{to}: #{reason}"
        end

        result = @http.request(
          method: :post, url: to,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(payload)
        )
        result[:status].to_i
      rescue Insika::DeliveryError
        raise
      rescue StandardError => e
        raise Insika::DeliveryError, "webhook: #{e.message}"
      end

      private

      # Resolved on EVERY delivery, not once at registration: a host that
      # answered a public address yesterday can answer 169.254.169.254 today,
      # and this POST carries the operator's alerts.
      def egress_violation(url)
        Insika::EgressGuard.violation(url, allow_http: @allow_http,
                                           allow_private: @allow_private)
      rescue URI::InvalidURIError
        "invalid URL"
      end
    end
  end
end

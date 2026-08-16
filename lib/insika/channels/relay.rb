# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "time"
require "uri"

module Insika
  module Channels
    # The channel for an adopter who ALREADY owns a messaging integration
    # A WhatsApp BSP, a Zendesk, a legacy Rails app: they want the
    # engine for the TURN, not for the platform. Two routes and an envelope —
    #
    #   consumer --POST /channels/relay/events--> engine   acked now, never the reply
    #   consumer <--POST <deliver_url>---------- engine    the reply, when there is one
    #
    # — and everything platform-shaped stays theirs: the 24-hour window, template
    # approval, media, read receipts, and how markdown becomes WhatsApp formatting
    # That is the promise, not the limitation: an integration someone has
    # already tuned for years does not have to move for them to adopt the engine.
    # A relay that starts growing template logic has stopped being a relay.
    #
    # It is also the cheapest possible Shape B, which is why it is built first:
    # both ends are ours, so there is no third-party signature scheme and no
    # rendering to get wrong at the same time as the durability. What it DOES
    # exercise — the outbox, the claim, bounded retry, inbound dedup — is what
    # Slack and native WhatsApp inherit untouched.
    #
    # R1/R2 hold: this object translates and authenticates, and does nothing else.
    # No Executor, no store, no RubyLLM; it may refuse a request, never grant a
    # capability.
    class Relay
      DEFAULT_ID = "relay"
      DEFAULT_TIMEOUT = 10

      # RFC-0027 C2: how the outbox flushes for THIS channel. `:at_end` (the
      # default) is one POST with the whole answer, byte-identical to today;
      # `:progressive` lets ChannelDelivery split the answer into balloons and
      # POST them in order (the channel still only translates — it does not know
      # what a balloon is).
      POLICIES = %i[at_end progressive].freeze

      attr_reader :id

      # The bundled relay as an operator configures it: three env vars, of which the
      # token is the SWITCH — no token, no channel, so there is no way to end up with
      # this route mounted and open. -> Relay | nil.
      #
      # `INSIKA_RELAY_SHADOW` (truthy) is the shadow switch (RFC-0025): the turn
      # runs end to end and the reply is recorded, never delivered.
      #
      # `INSIKA_RELAY_DELIVERY` ("progressive" | "at_end") is how the outbox
      # flushes (RFC-0027 C2). Unset = :at_end.
      #
      # Shared by every composition root on purpose: the DSL front door has to reach
      # the same feature as `config.ru`, or the docs are true of only one of them.
      def self.from_env(env = ENV, http: nil, allow_http: false, allow_private: false)
        token = Insika::EnvSchema.read("INSIKA_RELAY_TOKEN", env)
        return nil unless Insika::EnvSchema.present?(token)

        new(inbound_token: token,
            deliver_url: Insika::EnvSchema.read("INSIKA_RELAY_DELIVER_URL", env),
            deliver_token: Insika::EnvSchema.read("INSIKA_RELAY_DELIVER_TOKEN", env),
            shadow: Insika::EnvSchema.truthy?(Insika::EnvSchema.read("INSIKA_RELAY_SHADOW", env)),
            delivery: policy!(Insika::EnvSchema.read("INSIKA_RELAY_DELIVERY", env)),
            http: http, allow_http: allow_http, allow_private: allow_private)
      end

      # inbound_token:  shared secret the consumer sends us (Bearer). Blank ->
      #                 the channel answers :disabled to every request, fail-closed
      #                 by construction rather than open by omission.
      # deliver_url:    where the reply goes. Blank -> nothing is ever delivered
      #                 (the channel still accepts inbound; the outbox records the
      #                 reply and the delivery fails loudly instead of silently).
      # deliver_token:  Bearer we send THEM. Optional: a consumer on a private
      #                 network may authenticate us another way.
      # shadow:         RFC-0025. The turn runs, the reply is recorded and never
      #                 sent. Fail-closed by construction: everything downstream
      #                 duck-types `shadow?`, so a channel that does not answer it
      #                 is a normal channel.
      # delivery:       RFC-0027 C2. How the outbox flushes (:at_end | :progressive).
      def initialize(inbound_token:, deliver_url:, deliver_token: nil, http: nil,
                     id: DEFAULT_ID, allow_http: false, allow_private: false,
                     timeout: DEFAULT_TIMEOUT, shadow: false, delivery: :at_end)
        @id = id.to_s
        @inbound_token = inbound_token.to_s
        @deliver_url = deliver_url.to_s
        @deliver_token = deliver_token.to_s
        @http = http || Insika::HttpClient.new
        @allow_http = allow_http
        @allow_private = allow_private
        @timeout = timeout
        @shadow = shadow
        @delivery = self.class.policy!(delivery)
      end

      def shadow? = @shadow

      def delivery = @delivery
      def progressive? = @delivery == :progressive

      # "progressive" | "at_end" | blank/unset (= :at_end). An unknown value is
      # a config error at BOOT — the consumer would silently miss every
      # progressive turn, so it is refused where the operator is.
      def self.policy!(value)
        return :at_end if Insika::Coercion.blank?(value)

        name = value.to_s.strip.downcase.to_sym
        return name if POLICIES.include?(name)

        raise Insika::ConfigError,
              "unknown relay delivery: #{value.inspect} (expected #{POLICIES.join(', ')})"
      end

      # -> :ok | :unauthorized | :disabled. A SYMBOL and not a Rack triple (the
      # RFC sketched one): a status code is the transport's vocabulary, and keeping
      # it out of here is what lets this class be tested without Rack and read
      # without knowing HTTP.
      def authenticate(req)
        return :disabled if @inbound_token.empty?

        provided = req.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer (.+)\z/, 1]
        return :unauthorized if provided.nil?

        secure_compare(@inbound_token, provided) ? :ok : :unauthorized
      end

      # Inbound envelope -> the fields the mount turns into a `:send_message`.
      # STRING keys in, because the consumer's `vars` are arbitrary data keys.
      #
      #   { "agent": "support", "external_id": "5511999998888",
      #     "event_id": "wamid.HBg…", "message": "queria saber do pedido",
      #     "vars": { … } }
      #
      # In SHADOW mode `event_id` is REQUIRED: it is the correlation key both
      # halves of the pair are built from, and a mirror that cannot supply a
      # stable id cannot be paired.
      def parse(_req, body:)
        body = body.is_a?(Hash) ? body : {}
        agent = string(body["agent"])
        external_id = string(body["external_id"])
        message = string(body["message"])
        event_id = presence(body["event_id"])

        raise Insika::ValidationError, "agent is required" if agent.empty?
        raise Insika::ValidationError, "external_id is required" if external_id.empty?
        raise Insika::ValidationError, "message is required" if message.strip.empty?
        raise Insika::ValidationError, "event_id is required in shadow mode" if @shadow && event_id.nil?

        vars = body["vars"].is_a?(Hash) ? body["vars"] : {}
        { agent: agent, external_id: external_id, message: message,
          event_id: event_id, vars: vars, incumbent_reply: presence(body["incumbent_reply"]) }
      end

      # the engine namespaces the platform's conversation key, so a
      # Slack channel id and a phone number can never collide, an operator can see
      # where a conversation came from, and an id minted for one channel cannot be
      # used to read another's session.
      def session_id_for(external_id) = "#{@id}:#{external_id}"

      # The reverse: what the consumer called this conversation. Reads off the
      # session id so a delivery needs no extra state.
      def external_id_from(session_id)
        s = session_id.to_s
        s.start_with?("#{@id}:") ? s.delete_prefix("#{@id}:") : nil
      end

      # Hands ONE reply to the consumer's callback. -> the HTTP status (the
      # dispatcher decides what 2xx means); raises DeliveryError when the request
      # could not be made at all.
      #
      # `X-Insika-Delivery` is the outbox id: a stable idempotency key, so a
      # consumer that receives the same delivery twice (we retried after a timeout
      # that actually landed) can drop the second one.
      def deliver(payload, to:, delivery_id: nil)
        raise Insika::DeliveryError, "relay '#{@id}' is in shadow mode and must never deliver" if @shadow

        raise Insika::DeliveryError, "relay deliver_url is not configured" if @deliver_url.empty?

        if (reason = egress_violation)
          raise Insika::DeliveryError, "egress blocked for deliver_url: #{reason}"
        end

        response = @http.request(method: :post, url: @deliver_url, timeout: @timeout,
                                 headers: headers(delivery_id),
                                 body: JSON.generate(payload.merge("external_id" => to.to_s)))
        response[:status].to_i
      rescue Insika::DeliveryError
        raise
      rescue StandardError => e
        raise Insika::DeliveryError, "#{e.class}: #{e.message}"
      end

      # The reply, as recorded by the mirror (RFC-0025 C4, Shape 2). Follows the
      # same strictness as `parse`; `at` is optional (nil = now).
      def parse_shadow_reply(_req, body:)
        body = body.is_a?(Hash) ? body : {}
        external_id = string(body["external_id"])
        event_id = presence(body["event_id"])
        reply = string(body["reply"])

        raise Insika::ValidationError, "external_id is required" if external_id.empty?
        raise Insika::ValidationError, "event_id is required" if event_id.nil?
        raise Insika::ValidationError, "reply is required" if reply.strip.empty?

        at = presence(body["at"])
        raise Insika::ValidationError, "at must be an ISO8601 timestamp" if at && !parseable_time?(at)

        { external_id: external_id, event_id: event_id, reply: reply, at: at }
      end

      private

      def parseable_time?(value)
        Time.iso8601(value)
        true
      rescue ArgumentError
        false
      end

      # Resolved on EVERY call, not once at boot: a hostname that answered a public
      # address yesterday can answer 169.254.169.254 today, and this POST carries
      # the customer's conversation.
      def egress_violation
        Insika::EgressGuard.violation(@deliver_url, allow_http: @allow_http,
                                                    allow_private: @allow_private,
                                                    host_allowlist: [URI.parse(@deliver_url).host].compact)
      rescue URI::InvalidURIError
        "invalid URL"
      end

      def headers(delivery_id)
        h = { "content-type" => "application/json" }
        h["authorization"] = "Bearer #{@deliver_token}" unless @deliver_token.empty?
        h["x-insika-delivery"] = delivery_id.to_s if delivery_id
        h
      end

      # Constant time, and length-safe: comparing the digests means an attacker
      # learns nothing from how long the check took, not even the token's length.
      # OpenSSL rather than Rack::Utils so the engine's lib/ keeps no web framework
      # in its load path.
      def secure_compare(a, b)
        OpenSSL.fixed_length_secure_compare(Digest::SHA256.digest(a), Digest::SHA256.digest(b))
      end

      def string(value) = value.to_s
      def presence(value) = Insika::Coercion.presence(value)
    end
  end
end

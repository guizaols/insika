# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # C4 — the incumbent's half of a shadow pair, recorded on the mirror's
    # word. One command, two doors: Shape 1 (the reply rides the mirror call
    # itself) and Shape 2 (the follow-up route, for a consumer that mirrors
    # before answering) both dispatch HERE, so there is one behaviour and one
    # store method behind both.
    #
    # Idempotency is first-write-wins: the customer received ONE reply, and
    # letting a retry overwrite it would silently rewrite evidence. The
    # guarantee lives in ShadowPairStore#record_incumbent (inside its
    # transaction); the find below is only the cheap fast path for the common
    # retry. A reply for a pair that does not exist yet creates it :open — the
    # mirror may legitimately arrive before our turn finishes.
    class RecordShadowReply
      def initialize(shadow_pairs:, event_stream: nil)
        @shadow_pairs = shadow_pairs
        @event_stream = event_stream
      end

      # payload: { channel:, external_id:, event_id:, reply:, at: }
      # -> { pair_id:, status: }
      def call(command)
        payload = command.payload
        channel = Coercion.presence(payload[:channel] || payload["channel"])
        external_id = Coercion.presence(payload[:external_id] || payload["external_id"])
        event_id = Coercion.presence(payload[:event_id] || payload["event_id"])
        reply = payload[:reply] || payload["reply"]

        raise ValidationError, "channel is required" if channel.nil?
        raise ValidationError, "external_id is required" if external_id.nil?
        raise ValidationError, "event_id is required" if event_id.nil?
        raise ValidationError, "reply is required" if reply.to_s.strip.empty?

        id = ShadowPairStore.key_for(channel: channel, external_id: external_id,
                                     event_id: event_id)
        existing = @shadow_pairs.find(id)
        if existing && !existing.incumbent_reply.nil?
          emit(id, "already_recorded")
          return { pair_id: id, status: "already_recorded" }
        end

        pair = @shadow_pairs.record_incumbent(id: id, channel: channel, event_id: event_id,
                                              external_id: external_id, reply: reply.to_s,
                                              at: payload[:at] || payload["at"])
        emit(id, pair.status.to_s)
        { pair_id: id, status: pair.status.to_s }
      end

      private

      # Metadata only: the pair id and its status, never the reply's text.
      def emit(pair_id, status)
        return unless @event_stream

        @event_stream.emit(Insika::Event.new(
                             type: :shadow_reply_recorded,
                             data: { pair_id: pair_id, status: status },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end

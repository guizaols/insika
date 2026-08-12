# frozen_string_literal: true

require "time"

module Insika
  # Hands a finished turn's answer to a Shape B channel. The turn
  # ended; the recipient is not on any connection; the reply has to travel out of
  # band and survive a crash on the way. Three moves, in this order, and the order
  # is the whole design:
  #
  #   1. RECORD at the turn's terminal (durable, `pending`).
  #   2. CLAIM before the HTTP call (`pending -> delivering`, atomic). A crash
  #      between the claim and the POST loses that delivery; it does not duplicate
  #      it. At-most-once, stated rather than papered over — the same honest scope
  #      the async-delegation path already has.
  #   3. RETRY, bounded and explicit. Unlike a delegation, the recipient is a third
  #      party with outages, so "keep trying" is a real requirement and "keep trying
  #      forever" is a real outage of ours.
  #
  # It is NOT a job queue: no scheduler, no priorities, no fan-out. The moment it
  # grows one, the thing to do is take a real queue, not to finish building this.
  class ChannelDelivery
    MAX_ATTEMPTS = 3
    # Waits BETWEEN attempts, so attempt 1 is immediate. Short on purpose: a
    # customer waiting on WhatsApp is the deadline, not the consumer's SLA.
    BACKOFF_SECONDS = [1, 5].freeze

    def initialize(channels:, outbox:, session_store:, event_stream: nil,
                   max_attempts: MAX_ATTEMPTS, backoff: BACKOFF_SECONDS, sleeper: nil)
      @channels = channels
      @outbox = outbox
      @session_store = session_store
      @event_stream = event_stream
      @max_attempts = max_attempts
      @backoff = Array(backoff)
      @sleeper = sleeper || method(:default_sleep)
    end

    # The turn committed an answer. -> the Delivery to dispatch, or nil when there
    # is nothing to deliver, which is the common case and must stay cheap:
    #   · the turn did not come in through a channel,
    #   · the channel is Shape A (answers on its own stream — no `deliver`),
    #   · the answer is empty (a turn that died mid-message published nothing, and
    #     half a sentence was never an answer),
    #   · or we do not know who to send it to.
    def record(task:, channel_id:, content:)
      return nil if content.to_s.strip.empty?

      channel = @channels&.find(channel_id)
      return nil unless channel.respond_to?(:deliver)

      to = recipient(channel, task.session_id)
      return nil if to.nil? || to.empty?

      @outbox.create(
        channel: channel_id, to: to, task_id: task.id, session_id: task.session_id,
        payload: { "session_id" => task.session_id.to_s, "task_id" => task.id.to_s,
                   "content" => content.to_s }
      )
    end

    # Claim + POST + bounded retry. Safe to call twice: the second caller loses the
    # claim and returns without touching the recipient.
    def deliver(id)
      return false unless @outbox.claim(id)

      delivery = @outbox.find(id)
      channel = @channels&.find(delivery&.channel)
      # The channel vanished between the record and the dispatch (a plugin was
      # disabled, the deployment was reconfigured). Nothing can send this; leave it
      # terminal so the boot sweep does not spin on it forever.
      if channel.nil? || !channel.respond_to?(:deliver)
        return finish(@outbox.mark_failed(id, error: "channel '#{delivery&.channel}' is not registered"))
      end

      attempt(delivery, channel)
    end

    # Boot: re-drive what a previous process recorded and never claimed. Records
    # left `delivering` are deliberately NOT swept — that process may have POSTed
    # before it died, and replaying is the duplicate the claim exists to prevent.
    # -> { dispatched: [ids] }
    def sweep
      dispatched = @outbox.pending.map do |delivery|
        deliver(delivery.id)
        delivery.id
      end
      { dispatched: dispatched }
    end

    private

    def attempt(delivery, channel)
      last_error = nil

      @max_attempts.times do |i|
        @sleeper.call(@backoff[i - 1]) if i.positive? && @backoff[i - 1]

        begin
          status = channel.deliver(delivery.payload, to: delivery.to, delivery_id: delivery.id)
          return finish(@outbox.mark_delivered(delivery.id)) if (200..299).cover?(status.to_i)

          last_error = "HTTP #{status}"
        rescue Insika::DeliveryError => e
          last_error = e.message
        end
        @outbox.record_attempt(delivery.id, error: last_error)
      end

      finish(@outbox.mark_failed(delivery.id, error: last_error))
    end

    # The consumer's own key for this conversation. Written into the session's vars
    # when the channel minted it; the channel's own id parser is the fallback
    # for a session created before those vars existed.
    def recipient(channel, session_id)
      session = session_id && @session_store.find(session_id)
      vars = session&.vars || {}
      from_vars = vars["external_id"] || vars[:external_id]
      return from_vars.to_s if Insika::Coercion.presence(from_vars)

      channel.respond_to?(:external_id_from) ? channel.external_id_from(session_id) : nil
    end

    def finish(delivery)
      emit(delivery)
      delivery.status == :delivered
    end

    def emit(delivery)
      return unless @event_stream

      data = { channel: delivery.channel, outbox_id: delivery.id,
               status: delivery.status.to_s, attempts: delivery.attempts,
               error: delivery.last_error }
      meta = { task_id: delivery.task_id, session_id: delivery.session_id,
               at: Time.now.utc.iso8601 }
      # :delivery_failed is the ALERT face of a failed delivery (WS6) — emitted
      # alongside :channel_delivered so the delivery audit stream is unchanged.
      @event_stream.emit(Insika::Event.new(type: :channel_delivered, data: data, meta: meta))
      if delivery.status == :failed
        @event_stream.emit(Insika::Event.new(type: :delivery_failed, data: data, meta: meta))
      end
    end

    # Async when there is a reactor (production: the retry must not block the
    # worker), plain sleep otherwise (boot sweep before the reactor, specs).
    def default_sleep(seconds)
      task = defined?(Async::Task) ? Async::Task.current? : nil
      task ? task.sleep(seconds) : sleep(seconds)
    end
  end
end

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
  # It is NOT a job queue: no priorities, no fan-out. The moment it
  # grows one, the thing to do is take a real queue, not to finish building this.
  class ChannelDelivery
    MAX_ATTEMPTS = 3
    # Waits BETWEEN attempts, so attempt 1 is immediate. Short on purpose: a
    # customer waiting on WhatsApp is the deadline, not the consumer's SLA.
    BACKOFF_SECONDS = [1, 5].freeze

    def initialize(channels:, outbox:, session_store:, event_stream: nil,
                   max_attempts: MAX_ATTEMPTS, backoff: BACKOFF_SECONDS, sleeper: nil,
                   shadow_pairs: nil, criterion_sha: nil)
      @channels = channels
      @outbox = outbox
      @session_store = session_store
      @event_stream = event_stream
      @max_attempts = max_attempts
      @backoff = Array(backoff)
      @sleeper = sleeper || method(:default_sleep)
      @shadow_pairs = shadow_pairs
      @criterion_sha = criterion_sha
    end

    # the pair store and the frozen criterion's sha. Both default to
    # nil (parity — a graph without them behaves exactly as today); the server
    # root sets them at boot, after the criterion file has been loaded and
    # refused-or-accepted (the graph itself reads no env and no file).
    attr_writer :shadow_pairs, :criterion_sha

    # Confirmed answer -> 0..N pending Deliveries, in order .
    # A progressive channel splits on paragraphs (BalloonSplitter); everything
    # else is the single whole-answer row.
    # -> [] when there is nothing to send (the cheap exits):
    #   · the turn did not come in through a channel,
    #   · the channel is Shape A (answers on its own stream — no `deliver`),
    #   · the answer is empty (a turn that died mid-message published nothing, and
    #     half a sentence was never an answer),
    #   · the channel is in SHADOW mode: the answer is recorded as a
    #     pair and nothing is dispatched — zero outbox writes, ever (E1),
    #   · or we do not know who to send it to.
    #
    # `attachments` (evidence cards) ride the outbox payload as an
    # ADDITIVE key on the LAST balloon — a Shape B channel that reads `payload`
    # ignores it (JSON contract, additive); one that renders cards consumes it.
    def record_balloons(task:, channel_id:, content:, progressive:, attachments: nil)
      channel = @channels&.find(channel_id)
      return [] unless channel.respond_to?(:deliver)
      # Shadow records ONE pair for the whole answer — a balloon per paragraph
      # would mint N pairs for one turn.
      if shadow?(channel)
        record_shadow(task, channel_id, content)
        return []
      end

      return [] if content.to_s.strip.empty?

      to = recipient(channel, task.session_id)
      return [] if to.nil? || to.empty?

      parts = progressive ? Insika::BalloonSplitter.split(content) : [content.to_s]
      parts = parts.reject { |p| p.to_s.strip.empty? }
      return [] if parts.empty?

      multi = parts.size > 1
      parts.each_with_index.map do |part, i|
        last = i == parts.size - 1
        create_pending(task, channel_id, part, to,
                       index: multi ? i : nil, final: multi ? last : nil,
                       attachments: last ? attachments : nil)
      end
    end

    def shadow?(channel) = channel.respond_to?(:shadow?) && channel.shadow?

    # does this channel flush progressively? Duck-typed — a channel
    # that does not answer `progressive?` is `:at_end`.
    def progressive?(channel_id)
      channel = @channels&.find(channel_id)
      channel.respond_to?(:progressive?) && channel.progressive?
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

    # One outbox row for a confirmed balloon. `index`/`final` ride the payload
    # only when non-nil — a single-balloon progressive turn is indistinguishable
    # from an `:at_end` one on the wire. `index` also lands on the RECORD, which
    # is what the boot sweep orders by. `attachments` :
    # validated for the outbox — malformed entries dropped, never a turn failure.
    def create_pending(task, channel_id, content, to, index: nil, final: nil, attachments: nil)
      payload = { "session_id" => task.session_id.to_s, "task_id" => task.id.to_s,
                  "content" => content.to_s }
      payload["index"] = index if index
      payload["final"] = final unless final.nil?
      atts = Insika::Evidence.valid_attachments(attachments)
      payload["attachments"] = atts unless atts.empty?
      @outbox.create(channel: channel_id, to: to, task_id: task.id, session_id: task.session_id,
                     payload: payload, index: index.to_i)
    end

    # Our half of the shadow pair (C3). One store upsert on the turn's terminal,
    # then nil — `Executor#finalize_channel_delivery` returns without dispatching.
    # The ordering rules: no event_id -> :shadow_unpairable (C1 makes this
    # unreachable through the relay; a plugin channel could still get it wrong);
    # no pair store wired -> the same event (fail-closed, nothing delivered);
    # no recipient -> the same event (a pair keyed on an empty external_id can
    # never meet the mirror's half).
    def record_shadow(task, channel_id, content)
      command = task.respond_to?(:command) ? task.command : nil
      payload = command.is_a?(Hash) ? (command["payload"] || command[:payload] || {}) : {}
      agent = payload["agent"] || payload[:agent]
      message = payload["message"] || payload[:message]
      event_id = Insika::Coercion.presence(payload["event_id"] || payload[:event_id])
      if event_id.nil? || @shadow_pairs.nil?
        emit_shadow(:shadow_unpairable, channel_id, agent, nil, silent: nil)
        return nil
      end

      channel = @channels&.find(channel_id)
      external_id = recipient(channel, task.session_id)
      # The same empty-recipient guard the delivery path has: a pair keyed on an
      # empty external_id can never meet the mirror's half (its digest differs),
      # so the pair would sit :open forever. C1 makes this unreachable through
      # the relay; a plugin channel could still get it wrong.
      if Insika::Coercion.presence(external_id).nil?
        emit_shadow(:shadow_unpairable, channel_id, agent, nil, silent: nil)
        return nil
      end

      silent = content.to_s.strip.empty?
      id = Insika::ShadowPairStore.key_for(channel: channel_id, external_id: external_id,
                                           event_id: event_id)
      @shadow_pairs.record_ours(id: id, channel: channel_id, agent: agent,
                                session_id: task.session_id, task_id: task.id,
                                event_id: event_id, inbound: message.to_s,
                                reply: content.to_s, criterion_sha: @criterion_sha)
      emit_shadow(:shadow_recorded, channel_id, agent, id, silent: silent)
      nil
    end

    # Metadata only: the stream reaches every subscriber and stays free of
    # customer content, per the Studio's own emit_operator_action rule.
    def emit_shadow(type, channel, agent, pair_id, silent:)
      return unless @event_stream

      data = { channel: channel.to_s, agent: agent, pair_id: pair_id }.compact
      data[:silent] = silent unless silent.nil?
      @event_stream.emit(Insika::Event.new(type: type, data: data,
                                           meta: { at: Time.now.utc.iso8601 }))
    end

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

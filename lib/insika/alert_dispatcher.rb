# frozen_string_literal: true

require "digest"
require "time"

module Insika
  # Operator alerts to a webhook (WS6): the events `:budget_warning`,
  # `:breaker_open` and `:delivery_failed` are answered per AGENT — a profile
  # declaring `alerts: { "webhook" => url }` gets its alerts POSTed there as
  # JSON. The delivery reuses the outbox + claim mechanism whole
  # (`ChannelDelivery`): the handler only WRITES the outbox row; the existing
  # tick sweep and boot recovery claim and POST it, at-most-once with bounded
  # retry, via a registered `Channels::Webhook`. The engine transports the event
  # and does not interpret it — a Slack/CRM adapter is the consumer's.
  #
  # Started as a child of the turn supervisor (like the tick) in serving mode;
  # tests drive `handle` directly.
  class AlertDispatcher
    ALERT_TYPES = %i[budget_warning breaker_open delivery_failed].freeze

    def initialize(event_stream:, outbox:, channels:, profiles:, task_store: nil, http:)
      @event_stream = event_stream
      @outbox = outbox
      @channels = channels
      @profiles = profiles
      @task_store = task_store
      @http = http
      @webhook_ids = {} # url -> registered channel id (one webhook per URL)
      # WS6 (boot recovery): webhook channels are derived from PROFILE config,
      # not from events. Registering lazily (on the first alert) means a pending
      # outbox row a crashed process left is swept at boot against an EMPTY
      # registry and marked failed terminal. Pre-registering every configured
      # URL at wiring time lets the boot sweep find the channel and deliver.
      register_all_webhooks
    end

    # Serving: a long-lived consumer that answers every alert event. Drains on
    # the supervisor fiber (blocks on the queue — no spin), exactly like the tick.
    # It subscribes TYPED (only the alert events enter its queue — it answers
    # payloads a full-traffic stream would otherwise overflow away) and, on an
    # overflow close, RE-SUBSCRIBES: a consumer that never re-binds is how alerts
    # stop in silence (WS6).
    def start(parent:)
      parent.async do |t|
        t.annotate("insika-alerts")
        loop do
          subscription = @event_stream.subscribe(types: ALERT_TYPES)
          subscription.each { |event| handle(event) }
          # the subscription closed (its overflow path) — alerts must not die here
        end
      end
      true
    end

    # The event -> outbox row. Cheap (one transactional write); the DELIVERY is
    # the tick's job. Never raises: an alerting failure must not break the turn.
    def handle(event)
      type = event.type.to_s.to_sym
      return unless ALERT_TYPES.include?(type)

      agent = agent_for(event)
      return if agent.nil?

      profile = @profiles.respond_to?(:fetch) ? @profiles.fetch(agent.to_s) : nil
      return if profile.nil?

      url = profile&.respond_to?(:alerts) ? profile.alerts&.dig("webhook") : nil
      return if Coercion.blank?(url)

      record_alert(agent: agent.to_s, url: url.to_s, event: event)
    rescue StandardError
      nil
    end

    private

    # The agent the alert belongs to: the event carries it for the alerts the
    # engine emits with context (budget_warning / breaker_open); a
    # delivery_failed resolves its task's command. Guards the loop: a webhook's
    # OWN delivery failing is not re-alerted.
    def agent_for(event)
      case event.type.to_sym
      when :delivery_failed
        channel = event.data[:channel]
        return nil if channel.to_s.start_with?("webhook:") # loop guard
        agent_for_task(event.meta[:task_id])
      else
        event.data[:agent] || agent_for_task(event.meta[:task_id])
      end
    end

    def agent_for_task(task_id)
      return nil if task_id.nil? || @task_store.nil?

      task = @task_store.find(task_id.to_s)
      command = task&.respond_to?(:command) ? task.command : nil
      return nil unless command.is_a?(Hash)

      payload = command["payload"] || command[:payload] || {}
      payload["agent"] || payload[:agent]
    rescue StandardError
      nil
    end

    # The event's durable record, as the CHANNEL would see it. `to` is the
    # webhook URL; `payload` is the event itself (type/data/meta).
    def record_alert(agent:, url:, event:)
      channel = webhook_id(url)
      @outbox.create(
        channel: channel, to: url,
        task_id: event.meta[:task_id], session_id: event.meta[:session_id],
        payload: { "type" => event.type.to_s, "data" => event.data,
                   "meta" => event.meta, "agent" => agent }
      )
    end

    # One channel per URL, registered so ChannelDelivery.sweep can claim it.
    def webhook_id(url)
      @webhook_ids[url] ||= begin
        id = "webhook:#{Digest::SHA1.hexdigest(url)[0, 8]}"
        @channels.register(id, Channels::Webhook.new(url, http: @http))
        id
      end
    end

    # Boot face of `webhook_id`: register every configured URL up front (at
    # wiring time, before the boot recovery's channel sweep runs). The url is
    # PROFILE data, so it is known before any alert ever fires.
    def register_all_webhooks
      profiles = @profiles.respond_to?(:all) ? @profiles.all : []
      profiles.each do |profile|
        next unless profile&.respond_to?(:alerts)

        url = profile.alerts&.dig("webhook")
        webhook_id(url.to_s) unless Coercion.blank?(url)
      end
    end
  end
end
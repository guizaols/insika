# frozen_string_literal: true

require "time"

module Insika
  # Short-lived memory of inbound event ids, so a platform's retry does not become
  # a second LLM turn and a second reply.
  #
  # Every messaging platform retries a webhook it did not see acked in time, and a
  # relay consumer that hands us its own queue does the same. Without this, the
  # cost of one flaky ack is a duplicated turn (paid for) and a duplicated answer
  # (visible to the customer). With it, the retry finds the id and gets the SAME
  # task back — the caller learns it already sent this, which is a different fact
  # from "your message was merged into someone else's turn".
  #
  # The id is the CALLER's (`wamid.…`, a Slack event id, whatever the consumer's
  # queue uses). A caller that cannot supply a stable one gets at-least-once turns
  # and is told so in the docs — the engine does not hash the content and call
  # that dedup, because two customers legitimately typing "oi" one second apart is
  # not a duplicate.
  #
  # TTL, not forever: this is a retry window, not an audit log. An expired entry is
  # deleted lazily on read; `sweep` (boot) clears whatever nobody read back.
  class InboundLog
    SCOPE = "inbound"
    KEY_PREFIX = "inbound:"

    DEFAULT_TTL = 86_400 # 24h — longer than any platform's retry schedule

    def initialize(store:, ttl: DEFAULT_TTL, clock: -> { Time.now.utc })
      @store = store
      @ttl = ttl.to_i
      @clock = clock
    end

    # -> the task id this event already produced, or nil (never seen, or the
    # window closed). An expired entry is removed as it is read: the next
    # identical id is honestly a new message by then.
    def find(key)
      record = @store.get(SCOPE, key_for(key))
      return nil if record.nil?

      if expired?(record)
        @store.delete(SCOPE, key_for(key))
        return nil
      end
      record["task_id"]
    end

    # Remembers that `key` produced `task_id`. Last write wins, like every other
    # store — a re-record inside the window just refreshes the expiry.
    def record(key, task_id)
      @store.set(SCOPE, key_for(key), {
                   "key" => key.to_s,
                   "task_id" => task_id&.to_s,
                   "expires_at" => (@clock.call + @ttl).iso8601
                 })
      task_id
    end

    # Boot housekeeping: drops the entries nobody came back for. -> count removed.
    def sweep
      @store.list(SCOPE, KEY_PREFIX).count do |key|
        record = @store.get(SCOPE, key)
        next false unless record && expired?(record)

        @store.delete(SCOPE, key)
      end
    end

    private

    def expired?(record)
      at = record["expires_at"]
      return false if at.nil? # no expiry recorded -> keep (fail-safe, not fail-open)

      Time.parse(at.to_s) <= @clock.call
    rescue ArgumentError
      false
    end

    def key_for(key) = "#{KEY_PREFIX}#{key}"
  end
end

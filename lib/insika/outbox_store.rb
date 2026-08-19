# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # Durable record of one pending OUTBOUND reply. A Shape B
  # channel answers out of band — the turn ends and the reply is POSTed to the
  # platform (or, for a relay, to the consumer's own callback) afterwards — so
  # "the answer exists but the recipient is not on this connection" is exactly
  # the problem already solved for async delegation. This store
  # is DelegationStore's shape with a different recipient, deliberately: a second
  # invention here would be a second thing to get wrong.
  #
  # Lifecycle (never backwards):
  #   pending     the turn committed a reply; nobody has claimed it yet. This is
  #               the ONLY status the boot sweep re-drives.
  #   delivering  claimed. The claim happens BEFORE the HTTP call, so a crash
  #               here loses the delivery rather than duplicating it —
  #               at-most-once, the same honest scope as the delegation path.
  #   delivered   the recipient answered 2xx.
  #   failed      the bounded retry ran out. Terminal, and NOT re-driven at boot:
  #               a third party that refused N times is an operator problem, not
  #               something to replay forever.
  #
  # `failed` and `delivering` are a deliberate widening of the two-status
  # sketch (`pending -> delivered`): without them a crashed claim and an
  # exhausted retry are indistinguishable from a fresh record, and the sweep
  # would redeliver both.
  #
  # Normalizes symbol->string on WRITE (the backend only round-trips JSON types),
  # like every other domain store.
  class OutboxStore
    SCOPE = "outbox"
    KEY_PREFIX = "outbox:"

    STATUSES = %i[pending delivering delivered failed].freeze

    Delivery = Data.define(
      :id, :channel, :to, :task_id, :session_id, :payload,
      :status, :attempts, :last_error, :index, :created_at, :updated_at
    )

    def initialize(store:)
      @store = store
    end

    # -> Delivery (:pending). `payload` is the body the channel will send; it is
    # DATA (string keys, JSON types) and the store never interprets it.
    # `index`  is the balloon's position inside its turn — 0 for a
    # plain `:at_end` delivery, written by a progressive flush.
    def create(channel:, to:, task_id:, session_id:, payload:, index: 0, id: SecureRandom.uuid)
      record = {
        "id" => id.to_s,
        "channel" => channel.to_s,
        "to" => to.to_s,
        "task_id" => task_id&.to_s,
        "session_id" => session_id&.to_s,
        "payload" => payload,
        "status" => "pending",
        "attempts" => 0,
        "last_error" => nil,
        "index" => index.to_i,
        "created_at" => timestamp,
        "updated_at" => timestamp
      }
      @store.set(SCOPE, key_for(id), record)
      to_delivery(record)
    end

    # -> Delivery | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_delivery(record)
    end

    # -> [Delivery] still waiting for a first claim (boot sweep). Deliberately NOT
    # `delivering`: that one was claimed by a process that then died, and whether
    # its POST landed is unknowable — replaying it is the duplicate the claim
    # exists to prevent.
    #
    # Ordered by [task_id, index] : a crashed progressive turn re-drives
    # balloon 1 only after balloon 0, never the reverse.
    def pending
      scan.select { |d| d.status == :pending }
          .sort_by { |d| [d.task_id.to_s, d.index] }
    end

    # pending -> delivering, ATOMICALLY — across processes, not just fibers: the
    # read-check-write rides Store#transaction, so two workers claiming the same
    # record serialize on the backend's lock and only one sees :pending. Returns
    # true only for the caller that won the transition; that caller (and only it)
    # makes the HTTP call, so delivery is at-most-once even if the terminal hook
    # and the boot sweep both fire.
    def claim(id)
      @store.transaction do
        record = @store.get(SCOPE, key_for(id))
        next false unless record && record["status"] == "pending"

        record["status"] = "delivering"
        record["updated_at"] = timestamp
        @store.set(SCOPE, key_for(id), record)
        true
      end
    end

    # One attempt happened and did not succeed. Keeps the record :delivering (the
    # in-process retry loop owns it) and writes down why, so an operator reading
    # the store sees the third party's answer and not just a counter.
    def record_attempt(id, error: nil)
      record = fetch!(id)
      record["attempts"] = record["attempts"].to_i + 1
      record["last_error"] = error&.to_s
      touch(id, record)
    end

    # -> Delivery (:delivered). Idempotent: an already-delivered record is
    # returned unchanged rather than re-marked.
    def mark_delivered(id)
      record = fetch!(id)
      return to_delivery(record) if record["status"] == "delivered"

      record["status"] = "delivered"
      record["attempts"] = record["attempts"].to_i + 1
      record["last_error"] = nil
      touch(id, record)
    end

    # -> Delivery (:failed). The retry budget is spent; nothing re-drives this.
    def mark_failed(id, error: nil)
      record = fetch!(id)
      record["status"] = "failed"
      record["last_error"] = error&.to_s if error
      touch(id, record)
    end

    # WS8 (LGPD): drops every delivery of these sessions, whatever its status.
    # `payload` is the ANSWER as it was handed to the channel, so a purge that
    # stops at the session record leaves the conversation readable here forever.
    # -> count removed.
    def purge_sessions(session_ids)
      wanted = Array(session_ids).map(&:to_s)
      return 0 if wanted.empty?

      delete_where { |d| wanted.include?(d.session_id.to_s) }
    end

    # WS8 retention: deliveries created before the cutoff. TERMINAL ones only —
    # a `pending`/`delivering` record older than the window is still somebody's
    # undelivered answer, and the sweep is not the place to decide it is lost.
    # -> count removed.
    def delete_older_than(time)
      cutoff = time.utc.iso8601
      delete_where do |d|
        %i[delivered failed].include?(d.status) && d.created_at.to_s < cutoff
      end
    end

    private

    # The id list is SNAPSHOTTED before the deletes: `scan` enumerates the
    # backend's keys lazily and deleting under it would skip records.
    def delete_where(&match)
      doomed = scan.select(&match)
      doomed.each { |d| @store.delete(SCOPE, key_for(d.id)) }
      doomed.size
    end

    def scan
      return enum_for(:scan) unless block_given?

      @store.list(SCOPE, KEY_PREFIX).each do |key|
        record = @store.get(SCOPE, key)
        yield to_delivery(record) if record
      end
    end

    def fetch!(id)
      @store.get(SCOPE, key_for(id)) ||
        (raise Insika::NotFoundError, "outbox delivery not found: #{id}")
    end

    def touch(id, record)
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_delivery(record)
    end

    def key_for(id) = "#{KEY_PREFIX}#{id}"

    def to_delivery(record)
      Delivery.new(
        id: record["id"], channel: record["channel"], to: record["to"],
        task_id: record["task_id"], session_id: record["session_id"],
        payload: record["payload"], status: record["status"].to_sym,
        attempts: record["attempts"].to_i, last_error: record["last_error"],
        index: record["index"].to_i, created_at: record["created_at"],
        updated_at: record["updated_at"]
      )
    end

    def timestamp = Time.now.utc.iso8601
  end
end

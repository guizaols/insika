# frozen_string_literal: true

require "digest"
require "time"

module Insika
  # C2 — one durable record per mirrored exchange (shadow mode),
  # written by TWO INDEPENDENT HALVES: ours at the turn's terminal, the
  # incumbent's at the mirror. Both land on the same key — a digest of
  # (channel, external_id, event_id), deterministic and order-free — so the two
  # writers converge without an index and without ordering assumptions.
  #
  # It stores and it counts; it does not judge, does not fold a verdict, does
  # not know what the criterion says.
  #
  # Status transitions (never backwards):
  #
  #                 ┌─ record_incumbent ─┐
  #   (nothing) ────┤                    ├─▶ open ─▶ complete ─▶ judged
  #                 └─ record_ours ─────┘       └─▶ silent   (never judged)
  #                                             └─▶ incomplete (expire)
  class ShadowPairStore
    SCOPE = "shadow_pairs"
    KEY_PREFIX = "pair:"

    STATUSES = %i[open complete silent judged incomplete].freeze

    Pair = Data.define(
      :id, :channel, :agent, :session_id, :task_id, :event_id,
      :inbound, :incumbent_reply, :insika_reply,
      :status, :verdict, :criterion_sha, :created_at, :updated_at
    ) do
      def complete?      = %i[complete silent].include?(status)
      def judged?        = status == :judged
      def outcome        = verdict && verdict["outcome"]
      def human_assisted? = verdict && verdict["vs"] == "human-assisted"
    end

    def initialize(store:)
      @store = store
    end

    # The correlation key BOTH writers compute independently. SHA-256 hex of
    # "<channel>\0<external_id>\0<event_id>", truncated to 32 — deterministic,
    # order-free, and it keeps a phone number out of the store's key space.
    def self.key_for(channel:, external_id:, event_id:)
      Digest::SHA256.hexdigest("#{channel}\0#{external_id}\0#{event_id}")[0, 32]
    end

    # Our half. Upsert: creates the record or fills our fields on the incumbent's.
    # `reply` may be "" — a turn that published nothing (halt_when, an out-of-band
    # tool) is recorded as :silent rather than left invisible. -> Pair
    def record_ours(id:, channel:, agent:, session_id:, task_id:, event_id:,
                    inbound:, reply:, criterion_sha:)
      upsert(id) do |record, created|
        record["channel"] = channel.to_s
        record["event_id"] = event_id.to_s
        record["agent"] = agent
        record["session_id"] = session_id&.to_s
        record["task_id"] = task_id&.to_s
        record["inbound"] = inbound.to_s
        record["insika_reply"] = reply.to_s
        record["criterion_sha"] = criterion_sha
        created
      end
    end

    # The incumbent's half (the mirror contract). Same upsert shape; the fields
    # this half owns are the reply and, on first write, the timestamp the mirror
    # reports. Never overwrites our half's fields. First-write-wins is enforced
    # HERE, inside the transaction: the customer received ONE reply, and two
    # concurrent mirror retries must not let the second rewrite the evidence.
    # -> Pair
    def record_incumbent(id:, channel:, event_id:, external_id:, reply:, at: nil)
      upsert(id, at: at) do |record, created|
        record["channel"] = channel.to_s
        record["event_id"] = event_id.to_s
        record["incumbent_reply"] = reply.to_s if record["incumbent_reply"].nil?
        created
      end
    end

    # -> Pair | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_pair(record)
    end

    # Lazy scan over a SNAPSHOT of the keys (deleting under a live enumeration
    # would skip records — the same rule OutboxStore applies).
    def each(&block)
      return enum_for(:each) unless block_given?

      @store.list(SCOPE, KEY_PREFIX).each do |key|
        record = @store.get(SCOPE, key)
        yield to_pair(record) if record
      end
    end

    # -> [Pair] created at or after `time`.
    def since(time)
      cutoff = time.utc.iso8601
      each.select { |p| p.created_at.to_s >= cutoff }
    end

    # -> [Pair] status :complete, oldest first — the judging queue. `silent`
    # pairs are NEVER here:   finding that pairwise is
    # systematically unfair to a tool that delivers out of band is not
    # something to average away.
    def unjudged(limit: nil, agent: nil)
      pairs = each.select { |p| p.status == :complete }
                   .sort_by { |p| p.created_at.to_s }
      pairs = pairs.select { |p| p.agent.to_s == agent.to_s } if agent
      limit ? pairs.first(limit.to_i) : pairs
    end

    # -> { open:, complete:, silent:, judged:, incomplete: }
    def counts(since: nil)
      pairs = since ? self.since(since) : each.to_a
      STATUSES.to_h { |s| [s, pairs.count { |p| p.status == s }] }
    end

    # The panel's Verdict as data. status -> :judged. -> Pair
    def record_verdict(id, verdict:)
      @store.transaction do
        key = key_for(id)
        record = @store.get(SCOPE, key)
        raise Insika::NotFoundError, "shadow pair not found: #{id}" unless record

        record["verdict"] = Coercion.deep_stringify(verdict)
        record["status"] = "judged"
        record["updated_at"] = timestamp
        @store.set(SCOPE, key, record)
        to_pair(record)
      end
    end

    # An `open` pair older than the cutoff will never complete. -> count moved.
    # `complete`/`silent`/`judged` are never touched. Update-style only: a pair
    # deleted between the scan and the write (retention, LGPD purge) is left
    # deleted — an upsert here would resurrect it as a ghost :incomplete record
    # carrying none of its fields.
    def expire(older_than:)
      cutoff = older_than.utc.iso8601
      moved = 0
      each.select { |p| p.status == :open && p.created_at.to_s < cutoff }.each do |pair|
        @store.transaction do
          key = key_for(pair.id)
          record = @store.get(SCOPE, key)
          next unless record && record["status"] == "open"

          record["status"] = "incomplete"
          record["updated_at"] = timestamp
          @store.set(SCOPE, key, record)
          moved += 1
        end
      end
      moved
    end

    # -> Integer. Keys only, no record materialization — a count of pairs must
    # not pay for customer text (doctor's shadow-off check, the Studio).
    def size = @store.list(SCOPE, KEY_PREFIX).length

    # LGPD / retention (C9): drops every pair of these sessions, whatever its
    # status — the pair holds the customer's own words. -> count removed.
    def purge_sessions(session_ids)
      wanted = Array(session_ids).map(&:to_s)
      return 0 if wanted.empty?

      doomed = each.select { |p| wanted.include?(p.session_id.to_s) }
      doomed.each { |p| @store.delete(SCOPE, key_for(p.id)) }
      doomed.size
    end

    # Retention: pairs created before the cutoff, TERMINAL statuses only
    # (`judged`/`incomplete`) — an `open`/`complete` record older than the
    # window is still someone's unjudged evidence. -> count removed.
    def delete_older_than(time)
      cutoff = time.utc.iso8601
      doomed = each.select do |p|
        %i[judged incomplete].include?(p.status) && p.created_at.to_s < cutoff
      end
      doomed.each { |p| @store.delete(SCOPE, key_for(p.id)) }
      doomed.size
    end

    private

    # The shared upsert: read -> merge only the fields THIS half owns (never
    # overwrite the other's with nil) -> recompute status -> write. Runs inside
    # Store#transaction so two halves landing in the same instant serialize on
    # the backend's lock — the same claim mechanic OutboxStore#claim uses.
    def upsert(id, at: nil, &fill)
      @store.transaction do
        key = key_for(id)
        record = @store.get(SCOPE, key)
        created = record.nil?
        unless record
          record = {
            "id" => id.to_s, "channel" => nil, "agent" => nil, "session_id" => nil,
            "task_id" => nil, "event_id" => nil, "inbound" => nil,
            "incumbent_reply" => nil, "insika_reply" => nil, "status" => "open",
            "verdict" => nil, "criterion_sha" => nil,
            "created_at" => arrival_time(at), "updated_at" => timestamp
          }
        end
        fill.call(record, created)
        record["status"] = status_for(record)
        record["updated_at"] = timestamp
        @store.set(SCOPE, key, record)
        to_pair(record)
      end
    end

    # Status recomputation, in one place (never backwards — a judged pair stays
    # judged, an expired one stays incomplete):
    def status_for(record)
      return record["status"] if %w[judged incomplete].include?(record["status"])
      return "open" if record["insika_reply"].nil? || record["incumbent_reply"].nil?
      return "silent" if record["insika_reply"].to_s.strip.empty?

      "complete"
    end

    def key_for(id) = "#{KEY_PREFIX}#{id}"

    # The mirror's reported time on first write; nil = now. A String rides
    # through as-is (it is the wire format); a Time is normalized to ISO8601.
    # A String is ALSO normalized to UTC ISO8601: the mirrors report local
    # offsets (+09:00, -03:00) and every comparison against created_at
    # (since/expire/retention/unjudged ordering) is lexicographic — two offsets
    # would make those comparisons lie. Unparseable input keeps the old
    # ride-through behaviour rather than refusing the pair.
    def arrival_time(at)
      return timestamp if at.nil?
      return at.utc.iso8601 unless at.is_a?(String)

      Time.iso8601(at).utc.iso8601
    rescue ArgumentError
      at
    end

    def to_pair(record)
      Pair.new(
        id: record["id"], channel: record["channel"], agent: record["agent"],
        session_id: record["session_id"], task_id: record["task_id"],
        event_id: record["event_id"], inbound: record["inbound"],
        incumbent_reply: record["incumbent_reply"], insika_reply: record["insika_reply"],
        status: record["status"].to_sym, verdict: record["verdict"],
        criterion_sha: record["criterion_sha"],
        created_at: record["created_at"], updated_at: record["updated_at"]
      )
    end

    def timestamp = Time.now.utc.iso8601
  end
end

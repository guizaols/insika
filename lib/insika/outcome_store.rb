# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # WS7: business outcomes over real traffic, recorded per conversation by the
  # OPERATOR or the integration (`POST /v1/outcomes`) — `conversion`,
  # `escalation`, `deflected`, … optionally with a monetary `value`. The engine
  # TRANSPORTS the outcome and never interprets it (the same rule as alerts):
  # what "conversion" means is the operator's. Durable in the KV backend,
  # tenant-scoped (WS1) — a tenant can only ever read/write its own cells (the
  # key carries the tenant, and the read methods narrow on it).
  #
  # The Studio's scorecard card is the consumer: the LAST outcome per agent as
  # a state card, and per-period series — both fed from the same store, no
  # scheduler.
  class OutcomeStore
    SCOPE = "outcomes"

    Record = Data.define(:id, :tenant, :agent, :session_id, :outcome, :value, :at)

    def initialize(store:)
      @store = store
    end

    # -> Record. `at` defaults to now (UTC); `value` defaults to 0.0 (an
    # outcome without a value is a unit outcome).
    def create(tenant:, agent:, session_id: nil, outcome:, value: nil, id: SecureRandom.uuid, at: Time.now.utc)
      time = at.utc
      record = { "id" => id, "tenant" => tenant.to_s, "agent" => agent.to_s,
                 "session_id" => session_id.to_s, "outcome" => outcome.to_s,
                 "value" => value.to_f, "at" => time.iso8601 }
      @store.set(SCOPE, key(tenant, agent, time, id), record)
      to_record(record)
    end

    # All records, NEWEST first. `tenant:` narrows to one tenant's (WS1 — the
    # read path a tenant query uses); `agent:` narrows further. An outcome is a
    # fact, never a secret: the fields are ids, an outcome name and a number.
    def all(tenant: nil, agent: nil)
      records = @store.list(SCOPE).filter_map { |k| to_record(@store.get(SCOPE, k)) }
      records.select! { |r| r.tenant == tenant } if tenant
      records.select! { |r| r.agent == agent } if agent
      records.sort_by(&:at).reverse
    end

    # -> { agent => { outcome:, value:, at:, session_id: } }: the LAST outcome
    # per agent — the Studio's scorecard state card. A map so the agent grid
    # looks up in O(1) per card.
    def latest_per_agent(tenant: nil)
      all(tenant: tenant).each_with_object({}) do |r, acc|
        acc[r.agent] ||= { outcome: r.outcome, value: r.value, at: r.at,
                           session_id: r.session_id }
      end
    end

    # -> { "YYYY-MM-DD" => { outcome => { count:, value: } } } — per-period
    # series for the Studio. `period: :month` buckets by "YYYY-MM".
    def series(tenant: nil, agent: nil, period: :day)
      all(tenant: tenant, agent: agent).each_with_object({}) do |r, acc|
        bucket = period == :month ? r.at[0, 7] : r.at[0, 10]
        cell = ((acc[bucket] ||= {})[r.outcome] ||= { count: 0, value: 0.0 })
        cell[:count] += 1
        cell[:value] += r.value
      end
    end

    # Purges a tenant's records (WS8 phase 2 — delete_tenant_data). The tenant
    # is the FIRST key segment, so the purge is a prefix scan — the key IS the
    # isolation (WS1). -> count removed.
    def purge(tenant:)
      prefix = "#{tenant}:"
      keys = @store.list(SCOPE).select { |k| k.start_with?(prefix) }
      keys.each { |k| @store.delete(SCOPE, k) }
      keys.size
    end

    # Purges records older than the cutoff (WS8 retention — the tick's sweep).
    # `at` is ISO8601 UTC, so the comparison is lexicographic. -> count removed.
    def delete_older_than(time)
      cutoff = time.utc.iso8601
      removed = 0
      @store.list(SCOPE).each do |k|
        rec = @store.get(SCOPE, k)
        next unless rec && rec["at"].to_s < cutoff

        @store.delete(SCOPE, k)
        removed += 1
      end
      removed
    end

    private

    def key(tenant, agent, time, id)
      # tenant + agent + UTC date prefix: per-period / per-agent listing is a
      # prefix scan, and the tenant IS the first segment — WS1 isolation is the
      # key itself, like the session namespace.
      "#{(tenant || 'platform')}:#{agent}:#{time.strftime('%Y-%m-%d')}:#{id}"
    end

    def to_record(rec)
      return nil if rec.nil?

      Record.new(id: rec["id"], tenant: rec["tenant"], agent: rec["agent"],
                 session_id: rec["session_id"], outcome: rec["outcome"],
                 value: rec["value"].to_f, at: rec["at"])
    end
  end
end
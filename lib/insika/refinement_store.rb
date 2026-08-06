# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # REFINEMENT DOMAIN store (RFC-0013, phase A). One record per refinement RUN:
  # the window that was read, the ranked findings the EvidenceCollector produced,
  # and the run's outcome. RUNTIME data (it is derived from sessions/tasks/traces),
  # so it takes the raw `store:` like SessionStore/TaskStore — not the ConfigStore.
  #
  # The key embeds the agent and the start timestamp:
  #   "run:<agent_id>:<started_at>:<id>"
  # so `list(SCOPE, "run:<agent>:")` comes back CHRONOLOGICAL for that agent (the
  # Store contract orders lexicographically) and `latest_for` is its last element.
  # An agent id containing ":" would break that split, so it is rejected on write.
  #
  # Phase A writes no edits anywhere — a Run is a REPORT. The proposal/gate/apply
  # fields of RFC-0013 §3.2 arrive with phase C and are additive to this record.
  class RefinementStore
    include Coercion

    SCOPE = "refinements"
    KEY_PREFIX = "run:"

    # collecting -> completed | no_findings | failed (all terminal).
    STATUSES = %i[collecting completed no_findings failed].freeze

    Run = Data.define(:id, :agent_id, :status, :window, :findings,
                      :started_at, :finished_at, :error) do
      def terminal? = status != :collecting
      def findings_count = findings.size
    end

    def initialize(store:)
      @store = store
    end

    # Opens a run (:collecting). `window` is the collector's window as data
    # ({ "last_sessions" => N } | { "since" => iso8601 }) — recorded so a report can
    # be read months later and still say what it looked at. -> Run.
    def create(agent_id:, window: {}, id: SecureRandom.uuid, at: nil)
      agent = agent_id.to_s
      raise Insika::ValidationError, "agent_id is required" if agent.empty?
      raise Insika::ValidationError, "agent_id must not contain ':'" if agent.include?(":")

      started = at || timestamp
      record = {
        "id" => id.to_s, "agent_id" => agent, "status" => "collecting",
        "window" => deep_stringify(window || {}), "findings" => [],
        "started_at" => started, "finished_at" => nil, "error" => nil
      }
      @store.set(SCOPE, key_for(agent, started, id), record)
      to_run(record)
    end

    # Closes a run with its findings. Empty findings -> :no_findings (a distinct
    # outcome from :completed — "we looked and it was clean" is a real answer, not a
    # failure). -> Run. ArgumentError if the run is already terminal.
    def complete(id, findings:)
      update(id) do |record|
        guard_open!(record)
        list = Array(findings).map { |f| deep_stringify(f.respond_to?(:to_h) ? f.to_h : f) }
        record["findings"] = list
        record["status"] = list.empty? ? "no_findings" : "completed"
        record["finished_at"] = timestamp
      end
    end

    # Closes a run as :failed, recording the error. -> Run.
    def fail(id, error:)
      update(id) do |record|
        guard_open!(record)
        record["status"] = "failed"
        record["error"] = error.to_s
        record["finished_at"] = timestamp
      end
    end

    # -> Run | nil. O(n) scan over the scope (the key carries agent+timestamp, so
    # there is no index by id): one node, local SQLite, runs are operator-paced.
    def find(id)
      key = key_for_id(id)
      key && to_run(@store.get(SCOPE, key))
    end

    # -> [Run] for one agent, MOST RECENT FIRST, capped by `limit`.
    def for_agent(agent_id, limit: nil)
      keys = @store.list(SCOPE, "#{KEY_PREFIX}#{agent_id}:").reverse
      keys = keys.first(limit) if limit
      keys.filter_map { |k| to_run(@store.get(SCOPE, k)) }
    end

    # -> Run | nil (the agent's most recent run, whatever its status).
    def latest_for(agent_id) = for_agent(agent_id, limit: 1).first

    # -> [Run] across every agent, most recent first, capped.
    def recent(limit: 20)
      @store.list(SCOPE, KEY_PREFIX)
            .filter_map { |k| to_run(@store.get(SCOPE, k)) }
            .sort_by { |r| r.started_at.to_s }.reverse.first(limit)
    end

    private

    def key_for(agent, started_at, id) = "#{KEY_PREFIX}#{agent}:#{started_at}:#{id}"

    # The id is the key's last segment; scanning is the price of keeping the key
    # chronological (which is what every read except `find` actually wants).
    def key_for_id(id)
      suffix = ":#{id}"
      @store.list(SCOPE, KEY_PREFIX).find { |k| k.end_with?(suffix) }
    end

    def update(id)
      key = key_for_id(id)
      raise Insika::NotFoundError, "refinement run not found: #{id}" if key.nil?

      record = @store.get(SCOPE, key)
      raise Insika::NotFoundError, "refinement run not found: #{id}" if record.nil?

      yield record
      @store.set(SCOPE, key, record)
      to_run(record)
    end

    def guard_open!(record)
      return if record["status"] == "collecting"

      raise ArgumentError, "run #{record['id']} is already #{record['status']}"
    end

    def to_run(record)
      return nil if record.nil?

      Run.new(
        id: record["id"], agent_id: record["agent_id"],
        status: record["status"].to_sym, window: record["window"] || {},
        findings: record["findings"] || [],
        started_at: record["started_at"], finished_at: record["finished_at"],
        error: record["error"]
      )
    end

    def timestamp = Time.now.utc.iso8601
  end
end

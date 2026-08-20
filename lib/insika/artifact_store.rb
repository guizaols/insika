# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # The report destination: one record per run, no versioning, the listing
  # IS the history. A store, not a CMS.
  #
  # The tenant is a BINDING of the row — inherited from the agent that saved
  # the artifact (the tool reads it from the turn context, never from the
  # model), so a purge is a tenant-prefix scan and store A's report can never
  # appear in, or be linked from, store B.
  #
  # Record key: "<tenant>:<agent>:<id>" — per-tenant / per-agent scans are
  # prefixes; the id is the LAST segment, so a find is a suffix match (the
  # followup_store.rb idiom — there is no stable prefix for an id alone).
  # Blank tenant -> the literal "platform" (the outcome_store.rb rule, so the
  # purge prefix scans line up).
  class ArtifactStore
    SCOPE = "artifacts"

    # The mime allowlist — a page, not an attachment: no binaries, no uploads.
    MIMES = %w[text/html text/markdown image/svg+xml].freeze

    # The size cap on `content` (INSIKA_ARTIFACT_MAX_BYTES; the audio-message
    # precedent is 1 MB — an artifact is a page, not an attachment).
    DEFAULT_MAX_BYTES = 1_000_000
    TITLE_MAX = 200

    Record = Data.define(:id, :tenant, :agent, :task_id, :title, :mime,
                         :content, :created_at)

    def initialize(store:)
      @store = store
    end

    # -> Record. Validates the mime allowlist, a non-empty title (<= 200
    # chars) and content within `max_bytes` — ValidationError otherwise (the
    # tool returns it to the model as `{ error: }`).
    def create(tenant:, agent:, task_id:, title:, mime:, content:,
               id: SecureRandom.uuid, now: Time.now.utc, max_bytes: DEFAULT_MAX_BYTES)
      mime = "text/html" if mime.to_s.empty?
      raise Insika::ValidationError, "mime must be one of #{MIMES.join(', ')}, got #{mime.inspect}" unless MIMES.include?(mime.to_s)

      title = title.to_s
      raise Insika::ValidationError, "title is required (1..#{TITLE_MAX} chars)" if title.strip.empty? || title.length > TITLE_MAX

      content = content.to_s
      raise Insika::ValidationError, "content is required" if content.empty?
      raise Insika::ValidationError, "content exceeds #{max_bytes} bytes (#{content.bytesize})" if content.bytesize > max_bytes

      record = { "id" => id.to_s, "tenant" => tenant_id(tenant), "agent" => agent.to_s,
                 "task_id" => task_id.to_s, "title" => title, "mime" => mime.to_s,
                 "content" => content, "created_at" => now.iso8601 }
      @store.set(SCOPE, key(record), record)
      to_record(record)
    end

    # -> Record | nil. Suffix match over the scope's keys (no stable prefix
    # for an id alone — the followup_store.rb idiom).
    def find(id)
      key = @store.list(SCOPE).find { |k| k.end_with?(":#{id}") }
      key && to_record(@store.get(SCOPE, key))
    end

    # -> [Record] — one agent's artifacts, newest first (the listing IS the
    # history; the Studio tab's read).
    def for_agent(tenant:, agent:)
      prefix = "#{tenant_id(tenant)}:#{agent}:"
      @store.list(SCOPE).filter_map do |k|
        next unless k.start_with?(prefix)

        to_record(@store.get(SCOPE, k))
      end.sort_by { |r| [r.created_at.to_s, r.id] }.reverse
    end

    # -> [Record] — EVERY agent's artifacts for the tenant, newest first (the
    # Studio's "all" filter — same prefix scan as #purge, but reads instead of
    # deletes).
    def for_tenant(tenant:)
      prefix = "#{tenant_id(tenant)}:"
      @store.list(SCOPE).filter_map do |k|
        next unless k.start_with?(prefix)

        to_record(@store.get(SCOPE, k))
      end.sort_by { |r| [r.created_at.to_s, r.id] }.reverse
    end

    # -> bool (did it exist?).
    def delete(id)
      key = @store.list(SCOPE).find { |k| k.end_with?(":#{id}") }
      key ? @store.delete(SCOPE, key) : false
    end

    # -> count removed. The tenant-erasure reach — one tenant's artifacts die
    # with it, never a neighbour's.
    def purge(tenant:)
      prefix = "#{tenant_id(tenant)}:"
      keys = @store.list(SCOPE).select { |k| k.start_with?(prefix) }
      keys.each { |k| @store.delete(SCOPE, k) }
      keys.size
    end

    # -> count removed. The retention knob's reach (`artifact_ttl_days`) —
    # the guarantee that PII inside a report expires even though no reader
    # can see inside the opaque HTML.
    def delete_older_than(time)
      cutoff = time.utc.iso8601
      removed = 0
      @store.list(SCOPE).each do |k|
        record = @store.get(SCOPE, k)
        next unless record && record["created_at"].to_s < cutoff

        @store.delete(SCOPE, k)
        removed += 1
      end
      removed
    end

    private

    def key(record)
      "#{record['tenant']}:#{record['agent']}:#{record['id']}"
    end

    def tenant_id(tenant)
      t = tenant.to_s
      t.empty? ? "platform" : t
    end

    def to_record(rec)
      return nil if rec.nil?

      Record.new(id: rec["id"], tenant: rec["tenant"], agent: rec["agent"],
                 task_id: rec["task_id"], title: rec["title"], mime: rec["mime"],
                 content: rec["content"], created_at: rec["created_at"])
    end
  end
end
# frozen_string_literal: true

require "fileutils"
require "time"

module Insika
  # LEARNED concepts, one per agent (+ optional tenant). Holds the complete
  # concept markdown (frontmatter + body) in the durable Store, the same
  # content/updated_at/bounded-history record shape `SkillStore` uses for
  # SKILL.md — so the Studio's editor and undo work identically.
  #
  # Scoped like `MemoryStore` (agent/tenant baked into the scope string, not a
  # second constructor argument): a concept is engine-written, per-deployment
  # knowledge, never shared across agents the way a skill can be.
  #
  #   scope: "knowledge:<agent_id>"              # default
  #   scope: "knowledge:<agent_id>:<tenant>"      # explicit tenant (multi-merchant)
  #   key:   "concept:<name>"
  #
  # Record shape, one per concept:
  #   { "content" => "<entire concept markdown>", "updated_at" => iso8601,
  #     "history" => [ { "content" =>, "at" => }, ... ] }
  #
  # Layer 1 only: this is a plain upsert (last-write-wins, old version pushed
  # into history). Dedup/merge/conflict detection across sightings is layer 2,
  # not this store's job.
  class KnowledgeStore
    SCOPE_PREFIX = "knowledge"
    KEY_PREFIX = "concept:"
    HISTORY_MAX = 20

    def initialize(store:)
      @store = store
    end

    # -> String | nil (the complete concept markdown).
    def get(agent_id, name, tenant: nil)
      record(agent_id, name, tenant)&.fetch("content", nil)
    end

    # -> {"content" =>, "updated_at" =>} | nil. Cheap by design (no YAML
    # frontmatter parse) — `updated_at` is the raw record's OWN timestamp,
    # written on every upsert, so a caller can use it as a memoization key
    # (Index::Scan's read cache) without re-parsing content that has not
    # changed since the last read.
    def meta(agent_id, name, tenant: nil)
      rec = record(agent_id, name, tenant)
      rec && { "content" => rec["content"], "updated_at" => rec["updated_at"] }
    end

    # -> [String] concept names for the scope, lexicographic order.
    def names(agent_id, tenant: nil)
      @store.list(scope_for(agent_id, tenant), KEY_PREFIX).map { |k| k.delete_prefix(KEY_PREFIX) }
    end

    # -> { name => content } of every concept in the scope.
    def all(agent_id, tenant: nil)
      names(agent_id, tenant: tenant).each_with_object({}) { |n, acc| acc[n] = get(agent_id, n, tenant: tenant) }
    end

    # Upsert. -> Hash (the stored record).
    def write(agent_id, name, content, tenant: nil)
      key = name.to_s
      current = record(agent_id, key, tenant)
      rec = build_record(content.to_s, current)
      @store.set(scope_for(agent_id, tenant), KEY_PREFIX + key, rec)
      rec
    end

    # -> bool (did it exist?).
    def delete(agent_id, name, tenant: nil)
      @store.delete(scope_for(agent_id, tenant), KEY_PREFIX + name.to_s)
    end

    # -> [ { "content" =>, "at" => } ] most recent first.
    def versions(agent_id, name, tenant: nil)
      record(agent_id, name, tenant)&.fetch("history", []) || []
    end

    # Restores version `index` as the current content (a new write). -> Hash.
    def restore(agent_id, name, index, tenant: nil)
      hist = versions(agent_id, name, tenant: tenant)
      i = Integer(index)
      raise Insika::NotFoundError, "concept '#{name}' not found" unless record(agent_id, name.to_s, tenant)
      raise Insika::ValidationError, "version #{index} does not exist" if i.negative? || i >= hist.length

      write(agent_id, name, hist[i]["content"], tenant: tenant)
    end

    # Writes one `<dir>/<name>.md` per concept — the storage format IS the
    # export format, so this is a dump, not a converter: each file is the
    # concept's content, byte for byte, directly consumable by okf-gem
    # (`OKF::Bundle`) or graphify. Unlike a lossy re-serialization (YAML.dump
    # on a curated corpus, say), re-exporting the same store is idempotent —
    # no `force` guard needed, there is nothing here to lose. -> [paths].
    def export_dir(agent_id, dir, tenant: nil)
      FileUtils.mkdir_p(dir)
      names(agent_id, tenant: tenant).map do |name|
        path = File.join(dir, "#{name}.md")
        File.write(path, get(agent_id, name, tenant: tenant))
        path
      end
    end

    # -> String (one GraphML document — the whole scope as a graph, §5's
    # follow-up export shape). A record that fails to parse (a hand edit
    # gone wrong) is skipped rather than breaking the whole export.
    def export_graphml(agent_id, tenant: nil)
      concepts = names(agent_id, tenant: tenant).filter_map do |name|
        Knowledge::Concept.parse(get(agent_id, name, tenant: tenant))
      end
      Knowledge::GraphmlExport.build(concepts)
    end

    private

    def scope_for(agent_id, tenant)
      t = Coercion.presence(tenant)
      t ? "#{SCOPE_PREFIX}:#{agent_id}:#{t}" : "#{SCOPE_PREFIX}:#{agent_id}"
    end

    def record(agent_id, name, tenant)
      @store.get(scope_for(agent_id, tenant), KEY_PREFIX + name.to_s)
    end

    def build_record(content, current)
      history = current ? current.fetch("history", []) : []
      if current
        history = [{ "content" => current["content"], "at" => current["updated_at"] }] + history
        history = history.first(HISTORY_MAX)
      end
      # Microsecond precision ON PURPOSE (MemoryStore's own rule): `updated_at`
      # is Index::Scan's cache-invalidation key — second precision collides
      # for two writes in the same second (a backfill, a rapid consolidation),
      # and a collision there means a stale cached concept survives a real
      # write until the next search that lands in a different second.
      { "content" => content, "updated_at" => Time.now.utc.iso8601(6), "history" => history }
    end
  end
end

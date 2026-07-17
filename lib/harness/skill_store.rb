# frozen_string_literal: true

require "time"

module Harness
  # AUTHORED shared skills.
  # Holds the complete SKILL.md (frontmatter + body) in the durable Store. The
  # SkillCatalog overlays these skills on top of the on-disk ones (seed), with the Store
  # winning — so editing/creating a skill in the Studio takes effect without a restart (via reload).
  #
  # One record per skill in the ConfigStore (scope "skills"):
  #   { "content" => "<entire SKILL.md>",
  #     "updated_at" => iso8601,
  #     "history" => [ { "content" =>, "at" => }, ... ] }
  #
  # The key is the skill's canonical name (the same as in the frontmatter). Versions like
  # the AgentFileStore.
  class SkillStore
    SCOPE = "skills"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> String | nil (complete SKILL.md).
    def get(name)
      record(name)&.fetch("content", nil)
    end

    # -> [String] names, lexicographic order.
    def names = @cs.keys(SCOPE)

    # -> { name => content } of all authored skills.
    def all
      @cs.keys(SCOPE).each_with_object({}) { |n, acc| acc[n] = get(n) }
    end

    # Writes (upsert). create_only refuses to overwrite. -> Hash (the stored record).
    def write(name, content, create_only: false)
      key = name.to_s
      current = @cs.get(SCOPE, key)
      raise Harness::ValidationError, "skill '#{key}' já existe" if create_only && current

      rec = build_record(content.to_s, current)
      @cs.put(SCOPE, key, rec)
      rec
    end

    # -> bool (did it exist?).
    def delete(name) = @cs.delete(SCOPE, name.to_s)

    # -> [ { "content" =>, "at" => } ] most recent first.
    def versions(name) = record(name)&.fetch("history", []) || []

    # Restores version `index` as the current content (a new write). -> Hash.
    def restore(name, index)
      hist = versions(name)
      i = Integer(index)
      raise Harness::NotFoundError, "skill '#{name}' não encontrada" unless record(name)
      raise Harness::ValidationError, "versão #{index} inexistente" if i.negative? || i >= hist.length

      write(name, hist[i]["content"])
    end

    private

    def record(name) = @cs.get(SCOPE, name.to_s)

    def build_record(content, current)
      history = current ? current.fetch("history", []) : []
      if current
        history = [{ "content" => current["content"], "at" => current["updated_at"] }] + history
        history = history.first(HISTORY_MAX)
      end
      { "content" => content, "updated_at" => Time.now.utc.iso8601, "history" => history }
    end
  end
end

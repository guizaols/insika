# frozen_string_literal: true

require "time"

module Insika
  # AUTHORED skills, in two scopes.
  # Holds the complete SKILL.md (frontmatter + body) in the durable Store. The
  # SkillCatalog overlays these skills on top of the on-disk ones (seed), with the Store
  # winning — so editing/creating a skill in the Studio takes effect without a restart (via reload).
  #
  # SHARED scope (`agent:` omitted) — one record per skill in the ConfigStore
  # (scope "skills"), keyed by the skill name:
  #   { "content" => "<entire SKILL.md>",
  #     "updated_at" => iso8601,
  #     "history" => [ { "content" =>, "at" => }, ... ] }
  #
  # AGENT scope (`agent:` given) — one record per AGENT (scope "agent_skills"), the
  # skills nested under it, exactly the AgentFileStore shape:
  #   { "skills" => { "<name>" => { "content" =>, "updated_at" =>, "history" => [] } } }
  #
  # The agent dimension is a SECOND ARGUMENT, never part of the key. A composite
  # `"agent/name"` key would put a `/` inside what the Studio serves as a single path
  # segment (`GET /skills/:name`, the editor, the versions list) — the class of route
  # bug that ships green and 404s in production. Two arguments become two route
  # segments (`/agents/:id/skills/:name`) and nothing needs encoding.
  #
  # Two scopes and not one: the shared records are untouched by the arrival of the
  # agent dimension, so there is no migration and a live deployment keeps serving
  # exactly what it served.
  #
  # THE STORE POSITION IS THE IDENTITY. Which scope a record sits in — and under which
  # key — is what decides which skill it is; the frontmatter `name:` inside an override
  # stays the bare shared name. See SkillCatalog#find.
  class SkillStore
    SCOPE = "skills"
    AGENT_SCOPE = "agent_skills"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> String | nil (complete SKILL.md).
    def get(name, agent: nil)
      record(name, agent)&.fetch("content", nil)
    end

    # -> [String] names in the scope, lexicographic order.
    def names(agent: nil)
      agent.nil? ? @cs.keys(SCOPE) : agent_skills(agent).keys.sort
    end

    # -> { name => content } of the scope's authored skills.
    def all(agent: nil)
      names(agent: agent).each_with_object({}) { |n, acc| acc[n] = get(n, agent: agent) }
    end

    # -> [String] every agent that has specialized at least one skill. What the
    # catalog overlays and `doctor` sweeps.
    def agents = @cs.keys(AGENT_SCOPE).sort

    # Writes (upsert). create_only refuses to overwrite. -> Hash (the stored record).
    def write(name, content, agent: nil, create_only: false)
      key = name.to_s
      current = record(key, agent)
      raise Insika::ValidationError, "skill '#{key}' already exists#{" for agent '#{agent}'" if agent}" if create_only && current

      rec = build_record(content.to_s, current)
      put(key, rec, agent)
      rec
    end

    # -> bool (did it exist?).
    def delete(name, agent: nil)
      key = name.to_s
      return @cs.delete(SCOPE, key) if agent.nil?

      wrapper = @cs.get(AGENT_SCOPE, agent.to_s)
      return false unless wrapper&.dig("skills", key)

      wrapper["skills"].delete(key)
      @cs.put(AGENT_SCOPE, agent.to_s, wrapper)
      true
    end

    # -> [ { "content" =>, "at" => } ] most recent first.
    def versions(name, agent: nil) = record(name, agent)&.fetch("history", []) || []

    # Restores version `index` as the current content (a new write). -> Hash.
    def restore(name, index, agent: nil)
      hist = versions(name, agent: agent)
      i = Integer(index)
      raise Insika::NotFoundError, "skill '#{name}' not found" unless record(name.to_s, agent)
      raise Insika::ValidationError, "version #{index} does not exist" if i.negative? || i >= hist.length

      write(name, hist[i]["content"], agent: agent)
    end

    private

    def record(name, agent)
      return @cs.get(SCOPE, name.to_s) if agent.nil?

      agent_skills(agent)[name.to_s]
    end

    def put(key, rec, agent)
      return @cs.put(SCOPE, key, rec) if agent.nil?

      wrapper = @cs.get(AGENT_SCOPE, agent.to_s) || { "skills" => {} }
      wrapper["skills"] ||= {}
      wrapper["skills"][key] = rec
      @cs.put(AGENT_SCOPE, agent.to_s, wrapper)
    end

    def agent_skills(agent) = (@cs.get(AGENT_SCOPE, agent.to_s) || {})["skills"] || {}

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

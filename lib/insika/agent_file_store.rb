# frozen_string_literal: true

require "time"

module Insika
  # Per-agent workspace. Holds the
  # CONTENT of each agent's prompt files (IDENTITY.md/SOUL.md/TOOLS.md
  # and the like) in the durable Store — not on disk. It is what makes "each one
  # builds its own BIA with its own identity": the Prompt provider reads from
  # here, per agent, instead of the fixed `files:` in the wiring (which are now
  # only the deployment default).
  #
  # One record per agent in the ConfigStore (scope "agent_files"):
  #   { "files" => { "<name>" => { "content" => str,
  #                                "updated_at" => iso8601,
  #                                "history" => [ { "content" => str, "at" => iso8601 }, ... ] } } }
  #
  # A write versions: the previous content goes into `history` (most recent
  # first), capped at HISTORY_MAX — restoring becomes a new write
  # (preserves the linear history, no destructive "time travel").
  class AgentFileStore
    SCOPE = "agent_files"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> String | nil (current content; nil = nonexistent file/agent).
    def read(agent_id, filename)
      entry(agent_id, filename.to_s)&.fetch("content", nil)
    end

    # -> [String] the agent's file names, lexicographic order.
    def list(agent_id)
      files(agent_id).keys.sort
    end

    # -> [String] every agent that has a workspace here (what `doctor` sweeps).
    def agents = @cs.keys(SCOPE).sort

    # A prompt file is TEXT. `to_s` on a structured value produces Ruby's `#inspect`
    # and stores it as if it were the prompt: the pilot lost all 11 files of its
    # production agent that way (someone wrote an ENTRY back as content, so the
    # markdown reached the model as `{"content" => "…\n…"}` on a single line, escapes
    # and all, for three weeks). Nothing legitimate passes a Hash or an Array here, so
    # this is the one place that has to refuse instead of coerce.
    def self.text!(content, agent_id, filename)
      return content if content.is_a?(String)
      return content.to_s unless content.is_a?(Hash) || content.is_a?(Array)

      raise Insika::ValidationError,
            "content for '#{filename}' (agent '#{agent_id}') must be text, got #{content.class} — " \
            "pass the file's markdown, not the store entry or a wrapper object"
    end

    # Writes (upsert). create_only: refuses to overwrite. Versions the previous
    # content into history. -> Hash (the stored entry).
    def write(agent_id, filename, content, create_only: false)
      name = filename.to_s
      content = self.class.text!(content, agent_id, name)
      record = @cs.get(SCOPE, agent_id.to_s) || { "files" => {} }
      record["files"] ||= {}
      current = record["files"][name]
      if create_only && current
        raise Insika::ValidationError, "file '#{name}' already exists for agent '#{agent_id}'"
      end

      record["files"][name] = build_entry(content.to_s, current)
      @cs.put(SCOPE, agent_id.to_s, record)
      record["files"][name]
    end

    # -> bool (did it exist?). Removes the file; if the agent ends up with no files,
    # keeps the empty record (cheap; deleting the agent handles the cleanup).
    def delete(agent_id, filename)
      name = filename.to_s
      record = @cs.get(SCOPE, agent_id.to_s)
      return false unless record && record.dig("files", name)

      record["files"].delete(name)
      @cs.put(SCOPE, agent_id.to_s, record)
      true
    end

    # -> [ { "content" =>, "at" => } ] older versions, most recent first.
    def versions(agent_id, filename)
      entry(agent_id, filename.to_s)&.fetch("history", []) || []
    end

    # Restores version `index` from history as the current content (a new write:
    # the current one goes to the top of history). -> Hash (entry) | raises if index
    # invalid / file nonexistent.
    def restore(agent_id, filename, index)
      name = filename.to_s
      hist = versions(agent_id, name)
      i = Integer(index)
      unless entry(agent_id, name)
        raise Insika::NotFoundError, "file '#{name}' not found for agent '#{agent_id}'"
      end
      raise Insika::ValidationError, "version #{index} does not exist" if i.negative? || i >= hist.length

      write(agent_id, name, hist[i]["content"])
    end

    private

    def files(agent_id)
      (@cs.get(SCOPE, agent_id.to_s) || {})["files"] || {}
    end

    def entry(agent_id, filename)
      files(agent_id)[filename]
    end

    def build_entry(content, current)
      history = current ? current.fetch("history", []) : []
      if current
        history = [{ "content" => current["content"], "at" => current["updated_at"] }] + history
        history = history.first(HISTORY_MAX)
      end
      { "content" => content, "updated_at" => Time.now.utc.iso8601, "history" => history }
    end
  end
end

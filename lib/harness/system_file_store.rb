# frozen_string_literal: true

require "time"

module Harness
  # GLOBAL system files. These are prompts/rules
  # that apply to ALL agents in the deploy — the "house" above each BIA's
  # individual identity. Unlike the AgentFileStore (per agent), here there is no
  # tenant: one record per file in the ConfigStore (scope "system_files").
  #
  # Context::Providers::Prompt reads these files and injects them BEFORE the
  # per-agent identity, for every turn. With no system files (empty store),
  # the prompt is byte-for-byte the one from before (parity preserved) — the global
  # injection only exists when the operator authors something here.
  #
  # Record per file:
  #   { "content" => str, "updated_at" => iso8601,
  #     "history" => [ { "content" => str, "at" => iso8601 }, ... ] }
  #
  # A write versions (same contract as AgentFileStore): the previous content
  # goes into `history` (most recent first), capped at HISTORY_MAX; restoring
  # is a new write (linear history, no destructive "time travel").
  class SystemFileStore
    SCOPE = "system_files"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> String | nil (current content).
    def read(filename)
      entry(filename.to_s)&.fetch("content", nil)
    end

    # -> [String] file names, lexicographic order.
    def list
      @cs.keys(SCOPE).sort
    end

    # Writes (upsert). create_only: refuses to overwrite. Versions the previous one into
    # history. -> Hash (the stored entry).
    def write(filename, content, create_only: false)
      name = filename.to_s
      raise Harness::ValidationError, "file is required" if name.empty?

      current = entry(name)
      if create_only && current
        raise Harness::ValidationError, "system file '#{name}' already exists"
      end

      built = build_entry(content.to_s, current)
      @cs.put(SCOPE, name, built)
      built
    end

    # -> bool (did it exist?).
    def delete(filename)
      @cs.delete(SCOPE, filename.to_s)
    end

    # -> [ { "content" =>, "at" => } ] older versions, most recent first.
    def versions(filename)
      entry(filename.to_s)&.fetch("history", []) || []
    end

    # Restores version `index` from history as the current content (a new write).
    # -> Hash (entry) | raises if index invalid / file nonexistent.
    def restore(filename, index)
      name = filename.to_s
      current = entry(name)
      raise Harness::NotFoundError, "system file '#{name}' not found" unless current

      hist = current.fetch("history", [])
      i = Integer(index)
      raise Harness::ValidationError, "version #{index} does not exist" if i.negative? || i >= hist.length

      write(name, hist[i]["content"])
    end

    private

    def entry(name)
      @cs.get(SCOPE, name)
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

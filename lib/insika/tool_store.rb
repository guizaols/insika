# frozen_string_literal: true

require "time"

module Insika
  # DATA-DEFINED tools authored at runtime. One record per tool in the ConfigStore
  # (scope "tools"), keyed by name. It stores the whole ToolDefinition, versions it
  # (like SkillStore/AgentFileStore) and MASKS the credential headers (just as
  # McpStore masks the env): headers whose name is in `secret_headers` never
  # leave in plaintext to the UI — they become the sentinel `__OCULTO__`. Only `get_raw`/
  # `all_raw` (consumed by DataDefinedTool/overlay, never the screen) return the
  # real values. Phase 5, Step A.
  #
  # Record in the ConfigStore:
  #   { "definition" => { ...ToolDefinition#to_h... },
  #     "updated_at" => iso8601,
  #     "history"    => [ { "definition" =>, "at" => }, ... ] }
  class ToolStore
    SCOPE = "tools"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> MASKED ToolDefinition Hash (secret headers with sentinel) | nil.
    def get(name)
      d = raw_definition(name)
      d && mask_definition(d)
    end

    # -> ToolDefinition Hash with REAL headers | nil. Internal use (tool/overlay).
    def get_raw(name) = raw_definition(name)

    # -> [String] names, lexicographic order.
    def names = @cs.keys(SCOPE)

    # -> [Hash] MASKED definitions (for the UI).
    def all
      names.filter_map { |n| get(n) }
    end

    # -> [Hash] definitions with REAL headers (for the overlay/registry). Never to the screen.
    def all_raw
      names.filter_map { |n| raw_definition(n) }
    end

    # Writes (upsert). `attrs` is a ToolDefinition Hash (the UI may send secret
    # headers as sentinel: preserves what was stored). create_only refuses to overwrite.
    # Validates via ToolDefinition.from_h. -> MASKED definition Hash.
    def write(attrs, create_only: false)
      definition = Insika::ToolDefinition.from_h(attrs)   # validates (raises ValidationError)
      name = definition.name
      existing = @cs.get(SCOPE, name)
      raise Insika::ValidationError, "tool '#{name}' already exists" if create_only && existing

      final = definition.to_h
      final["request"]["headers"] = reconcile_secret_headers(
        final["request"]["headers"], definition.secret_headers,
        existing&.dig("definition", "request", "headers")
      )

      rec = build_record(final, existing)
      @cs.put(SCOPE, name, rec)
      mask_definition(final)
    end

    # -> bool (did it exist?).
    def delete(name) = @cs.delete(SCOPE, name.to_s)

    # -> [ { "definition" => MASKED, "at" => } ] most recent first.
    def versions(name)
      (record(name)&.fetch("history", []) || []).map do |h|
        { "definition" => mask_definition(h["definition"]), "at" => h["at"] }
      end
    end

    # Restores version `index` as the current definition (new write, versions the current).
    # -> MASKED definition Hash.
    def restore(name, index)
      rec = record(name)
      raise Insika::NotFoundError, "tool '#{name}' not found" unless rec

      hist = rec.fetch("history", [])
      i = Integer(index)
      raise Insika::ValidationError, "version #{index} does not exist" if i.negative? || i >= hist.length

      # The historical version stores REAL headers -> rewrite directly (bypasses the
      # input masking; write only re-validates the structure).
      write(hist[i]["definition"])
    end

    private

    def record(name) = @cs.get(SCOPE, name.to_s)

    def raw_definition(name) = record(name)&.fetch("definition", nil)

    def build_record(definition, current)
      history = current ? current.fetch("history", []) : []
      if current
        history = [{ "definition" => current["definition"], "at" => current["updated_at"] }] + history
        history = history.first(HISTORY_MAX)
      end
      { "definition" => definition, "updated_at" => Time.now.utc.iso8601, "history" => history }
    end

    # Each header in secret_headers becomes a sentinel; the rest pass through intact.
    def mask_definition(definition)
      secret = definition["secret_headers"] || []
      return definition if secret.empty?

      headers = (definition.dig("request", "headers") || {}).each_with_object({}) do |(k, v), acc|
        acc[k] = secret.include?(k) ? SecretMasking.mask(v) : v
      end
      definition.merge("request" => definition["request"].merge("headers" => headers))
    end

    # Reconciles ONLY the secret headers against what was stored: sentinel preserves,
    # a new string replaces, "" clears (removes the key). Non-secret pass through intact.
    def reconcile_secret_headers(incoming, secret_names, existing)
      old = existing || {}
      secret_names.each_with_object(incoming.dup) do |hname, acc|
        next unless acc.key?(hname)

        value = SecretMasking.reconcile(acc[hname], old[hname])
        if value.nil? || value.to_s.empty?
          acc.delete(hname)
        else
          acc[hname] = value
        end
      end
    end
  end
end

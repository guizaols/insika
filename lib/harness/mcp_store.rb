# frozen_string_literal: true

module Harness
  # MCP instances authored at runtime. One
  # record per instance in the ConfigStore (scope "mcp"), keyed by the name slug
  # (`tavily`, `github`, ...). Holds transport/command/url, the `enabled` flag and
  # a Hash of `env` credentials (tokens/keys the instance injects into the server).
  #
  # The credentials (`env`) NEVER leave here in plaintext to the UI: the display
  # reads (`get`/`all`) mask EACH value with the `__OCULTO__` sentinel. Only
  # `get_raw`/`all_raw` (consumed by an MCP client, never by the screen) return
  # the real values. On write, the sentinel coming back preserves the value; a new
  # string replaces it; "" clears it (see Harness::SecretMasking, the same pattern
  # as the LLM api_keys).
  #
  # Current scope: durable config CRUD (the instances UI). Running an MCP client
  # against these instances is later runtime work — the store is the editable
  # source from now on.
  class McpStore
    include Coercion

    SCOPE = "mcp"

    def initialize(config_store:)
      @cs = config_store
    end

    # -> MASKED Hash (env with sentinel) | nil.
    def get(name)
      mask(raw(name))
    end

    # -> Hash with REAL env | nil. Internal use (MCP client), never the screen.
    def get_raw(name)
      raw(name)
    end

    # -> [String] slugs, lexicographic order.
    def names = @cs.keys(SCOPE)

    # -> [Hash] all MASKED (for the UI).
    def all
      names.filter_map { |n| get(n) }
    end

    # -> [Hash] all with REAL env (for an MCP client). Never goes to the screen.
    def all_raw
      names.filter_map { |n| raw(n) }
    end

    # Upsert with per-env-key secret reconciliation. `attrs`
    # (string|symbol keys):
    #   name (required), transport, command, url, description,
    #   enabled (bool), env ({ "KEY" => value|sentinel|"" })
    # -> MASKED Hash (the stored record).
    def upsert(attrs)
      h = symbolize(attrs)
      name = presence(h[:name])
      raise Harness::ValidationError, "name is required" if name.nil?

      existing = raw(name)
      record = {
        "name" => name,
        "transport" => presence(h[:transport]) || "stdio",
        "command" => presence(h[:command]),
        "url" => presence(h[:url]),
        "description" => presence(h[:description]),
        "enabled" => h.fetch(:enabled, true) ? true : false,
        "env" => reconcile_env(h[:env], existing && existing["env"])
      }
      @cs.put(SCOPE, name, record)
      mask(record)
    end

    # -> bool (did it exist?).
    def delete(name) = @cs.delete(SCOPE, name.to_s)

    private

    def raw(name) = @cs.get(SCOPE, name.to_s)

    # Each env value becomes the sentinel (or disappears if empty) — never leaks plaintext.
    def mask(record)
      return nil if record.nil?

      env = (record["env"] || {}).each_with_object({}) do |(k, v), acc|
        acc[k] = SecretMasking.mask(v)
      end
      record.merge("env" => env)
    end

    # Reconciles the env received from the form against the stored one, key by key: a
    # key that came as the sentinel is preserved; a new string replaces it; "" (or missing
    # from the submission) clears it. NEW keys are added; old keys absent from the form
    # are removed (the form sends the complete set of keys).
    def reconcile_env(incoming, existing)
      inc = stringify_hash(incoming)
      old = existing || {}
      inc.each_with_object({}) do |(k, v), acc|
        value = SecretMasking.reconcile(v, old[k])
        acc[k] = value unless value.nil? || value.to_s.empty?
      end
    end

    def stringify_hash(obj)
      return {} unless obj.is_a?(Hash)

      obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def symbolize(attrs)
      (attrs || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end
  end
end

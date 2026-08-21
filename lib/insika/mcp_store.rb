# frozen_string_literal: true

module Insika
  # MCP instances authored at runtime. One
  # record per instance in the ConfigStore (scope "mcp"), keyed by the name slug
  # (`tavily`, `github`, ...). Holds transport/command/args/url, the `enabled`
  # flag, and two credential Hashes: `env` (stdio child-process environment) and
  # `headers` (http/sse request headers) — see RFC-0040. `env` used to double as
  # "HTTP headers" for http/sse instances; a record written under that old
  # meaning is migrated ON READ (see `migrate_legacy_headers!`), never rewritten
  # silently (`insika doctor` flags it so the operator re-saves it explicitly).
  #
  # Credentials (`env`/`headers`) NEVER leave here in plaintext to the UI: the
  # display reads (`get`/`all`) mask EACH value with the `__OCULTO__` sentinel.
  # Only `get_raw`/`all_raw` (consumed by Insika::McpClient, never by the
  # screen) return the real values. On write, the sentinel coming back
  # preserves the value; a new string replaces it; "" clears it (see
  # Insika::SecretMasking, the same pattern as the LLM api_keys).
  #
  # Current scope: durable config CRUD (the instances UI) + the shape
  # Insika::McpClient.for reads. Live tool execution is later runtime work.
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

    # Upsert with per-key secret reconciliation. `attrs`
    # (string|symbol keys):
    #   name (required), transport, command, args ([String, ...]), url,
    #   description, enabled (bool), env ({ "KEY" => value|sentinel|"" }),
    #   headers ({ "Header-Name" => value|sentinel|"" })
    # -> MASKED Hash (the stored record).
    def upsert(attrs)
      h = symbolize(attrs)
      name = presence(h[:name])
      raise Insika::ValidationError, "name is required" if name.nil?

      existing = raw(name)
      record = {
        "name" => name,
        "transport" => presence(h[:transport]) || "stdio",
        "command" => presence(h[:command]),
        "args" => Array(h[:args]).map(&:to_s).reject(&:empty?),
        "url" => presence(h[:url]),
        "description" => presence(h[:description]),
        "enabled" => h.fetch(:enabled, true) ? true : false,
        "env" => reconcile_hash(h[:env], existing && existing["env"]),
        "headers" => reconcile_hash(h[:headers], existing && existing["headers"])
      }
      @cs.put(SCOPE, name, record)
      mask(record)
    end

    # -> bool (did it exist?).
    def delete(name) = @cs.delete(SCOPE, name.to_s)

    # -> [String] names of http/sse instances still stored under the pre-
    # RFC-0040 meaning of `env` (`insika doctor`'s "mcp" check; `raw`/`all_raw`
    # already read them correctly — this is only to flag the ones that still
    # need a re-save so the stored record itself catches up).
    def legacy_header_names
      names.select { |n| needs_header_migration?(@cs.get(SCOPE, n)) }
    end

    private

    def raw(name) = migrate_legacy_headers(@cs.get(SCOPE, name.to_s))

    # A record written before RFC-0040 used `env` as HTTP headers for an
    # http/sse instance. On READ ONLY (never rewritten silently — `insika
    # doctor` flags it via `legacy_header_names` so the operator re-saves it
    # explicitly), an http/sse record with `env` set and no `headers` yet is
    # read as if `env` had been `headers` all along. A stdio record's `env` is
    # untouched — it always meant process environment.
    def migrate_legacy_headers(record)
      return record unless needs_header_migration?(record)

      record.merge("headers" => record["env"], "env" => {})
    end

    def needs_header_migration?(record)
      return false if record.nil? || !http_like?(record["transport"])

      (record["env"] || {}).any? && (record["headers"] || {}).empty?
    end

    def http_like?(transport) = %w[http sse].include?(transport.to_s)

    # Each env/headers value becomes the sentinel (or disappears if empty) — never leaks plaintext.
    def mask(record)
      return nil if record.nil?

      record.merge(
        "env" => mask_hash(record["env"]),
        "headers" => mask_hash(record["headers"])
      )
    end

    def mask_hash(hash)
      (hash || {}).each_with_object({}) { |(k, v), acc| acc[k] = SecretMasking.mask(v) }
    end

    # Reconciles a credential Hash received from the form against the stored one, key by
    # key: a key that came as the sentinel is preserved; a new string replaces it; "" (or
    # missing from the submission) clears it. NEW keys are added; old keys absent from the
    # form are removed (the form sends the complete set of keys).
    def reconcile_hash(incoming, existing)
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

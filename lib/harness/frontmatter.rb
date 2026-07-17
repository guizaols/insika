# frozen_string_literal: true

require "yaml"

module Harness
  # TOLERANT frontmatter parser (the YAML `--- ... ---` block of a SKILL.md).
  # The convention is YAML, but real packs carry PROSE in `description` — with `: `
  # (colon + space), quotes, parentheses — which STRICT YAML rejects
  # ("mapping values are not allowed in this context"). The OpenClaw gateway
  # tolerates it; the harness has to tolerate it too (NF2: the same pack must hold).
  #
  # Strategy: try YAML (respects quoted / multi-line / lists); if the YAML
  # fails OR doesn't yield a Hash, fall back to a LINE-BY-LINE parse that splits on
  # the FIRST `:` and treats the rest as a raw string — recovers name/description
  # even with `: ` in the middle of the value. -> Hash with String keys. NEVER raises.
  module Frontmatter
    module_function

    def parse(text)
      loaded = begin
        YAML.safe_load(text.to_s)
      rescue Psych::SyntaxError
        nil
      end
      loaded.is_a?(Hash) ? stringify(loaded) : lenient(text)
    end

    # Split on the first `:` of each line; value = the rest (string). A line
    # without `:` is ignored. Preserves `: ` internal to the value (the case that breaks YAML).
    def lenient(text)
      text.to_s.each_line.each_with_object({}) do |line, acc|
        next unless line.include?(":")

        key, _, value = line.partition(":")
        k = key.strip
        acc[k] = value.strip unless k.empty?
      end
    end

    def stringify(hash) = hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
  end
end

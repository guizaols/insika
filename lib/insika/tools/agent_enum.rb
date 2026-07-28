# frozen_string_literal: true

module Insika
  module Tools
    # Names the parent's subagent allowlist INSIDE the delegation tools' schema.
    #
    # The allowlist is per-turn data (`profile.subagents`), while a RubyLLM tool's
    # schema is class-level, so the enum has to be injected per instance. Without
    # it the model is told only that `agent` "must be one this agent may spawn" and
    # is left to guess the ids; with it, the valid values are part of the contract
    # the provider sees.
    #
    # Tolerant by construction: JSON-schema hashes reach us with symbol keys (the
    # class-level `params(...)` form) or string keys (anything that round-tripped
    # through JSON), and a shape we do not recognize is returned UNTOUCHED — a
    # schema we failed to annotate still works, one we corrupted would break every
    # delegation.
    module AgentEnum
      module_function

      # schema: the tool's JSON schema · allowed: [String] · path: the property
      # chain leading to the `agent` property, e.g. %i[agent] or %i[tasks agent].
      # -> a COPY with `enum` set, or the original when there is nothing to do.
      def inject(schema, allowed, path:)
        return schema if schema.nil? || Array(allowed).empty?

        copy = deep_dup(schema)
        target = resolve(copy, path)
        return schema if target.nil?

        target[key_for(target, :enum)] = Array(allowed).map(&:to_s)
        copy
      end

      # Walks `properties` (and `items` for an array) down to the named property.
      def resolve(node, path)
        path.reduce(node) do |current, segment|
          props = fetch(current, :properties)
          props = fetch(fetch(current, :items) || {}, :properties) if props.nil?
          prop = props && (props[segment] || props[segment.to_s])
          return nil unless prop.is_a?(Hash)

          prop
        end
      end

      def fetch(node, key)
        return nil unless node.is_a?(Hash)

        node[key] || node[key.to_s]
      end

      # Keep the hash's own key convention instead of mixing symbols into a
      # string-keyed schema.
      def key_for(hash, key)
        hash.keys.any? { |k| k.is_a?(String) } ? key.to_s : key
      end

      def deep_dup(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), acc| acc[k] = deep_dup(v) }
        when Array then value.map { |v| deep_dup(v) }
        else value
        end
      end
    end
  end
end

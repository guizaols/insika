# frozen_string_literal: true

require "digest/sha2"

module Insika
  #   — the cache-prefix hash chain. Inputs are the SYSTEM-placement
  # fragments in canonical render order (the Builder's sort, C3) and the tool
  # schema serialization — the same yardstick the token estimate uses
  # (name + description + parameters.inspect, executor.rb:957). Outputs are
  # PII-free digests: it never sees message text, only hashes leave this class.
  # Pure stdlib (digest/sha2), no gem, no IO.
  #
  # The chain follows the cache boundary: the cumulative "prefix" is over the
  # IDENTITY categories + tool_schemas only — the bytes the cache breakpoint
  # actually covers. Volatile categories (memory, knowledge, briefing, request)
  # render below the breakpoint, so a change there is not a prefix invalidation;
  # they still get their own digest (the trace shows them) but sit AFTER the
  # "prefix" key, outside the chain.
  class PrefixFingerprint
    # -> { "prompt" => "sha256…", …, "tool_schemas" => "sha256…",
    #      "prefix" => "sha256…", "memory" => "sha256…", … }
    # Keys are the demodulized, downcased provider ids. Order: identity
    # categories (render order), "tool_schemas", "prefix", then the volatile
    # categories — everything before "prefix" is the chain.
    # A category with no fragments is absent (not an empty hash).
    # The category digest = SHA256 of the category's fragments joined "\n\n"
    # (the Builder's separator — the digest matches rendered bytes).
    # "prefix" = SHA256 of the chain digests concatenated in order — any
    # divergence anywhere above the boundary changes it. A fragment with no
    # layer stamp reads as volatile, like everywhere else.
    def self.compute(system_fragments, tool_serial:)
      identity, volatile = system_fragments.partition { |f| (f.layer || :volatile) == :identity }
      digests = category_digests(identity)
      digests["tool_schemas"] = digest(tool_serial.to_s) unless tool_serial.nil?
      digests["prefix"] = digest(digests.values.join) unless digests.empty?
      digests.merge(category_digests(volatile))
    end

    # -> String | nil. nil when the cumulative "prefix" did not move (a
    # volatile change is not an invalidation). Else the first chain category
    # (in CURRENT chain order) whose digest differs or is absent from
    # `previous`; else the first PREVIOUS chain key now absent from the current
    # chain (a vanished block is a divergence too). nil `previous` (first turn)
    # -> nil. The returned name is a category id — PII-free by construction.
    def self.invalidation_reason(current, previous)
      return nil unless previous.is_a?(Hash)
      return nil if current["prefix"] == previous["prefix"]

      chain(current).find { |name| previous[name] != current[name] } ||
        (chain(previous) - current.keys).first
    end

    def self.chain(map) = map.keys.take_while { |k| k != "prefix" }

    def self.category_digests(fragments)
      fragments.group_by { |f| category(f.source) }
               .transform_values { |frags| digest(frags.map(&:content).join("\n\n")) }
    end

    def self.category(source) = source.to_s.split("::").last.to_s.downcase
    def self.digest(bytes) = Digest::SHA256.hexdigest(bytes)
  end
end

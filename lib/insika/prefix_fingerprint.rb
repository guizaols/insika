# frozen_string_literal: true

require "digest/sha2"

module Insika
  # RFC-0030 C2 — the cache-prefix hash chain. Inputs are the SYSTEM-placement
  # fragments in canonical render order (the Builder's sort, C3) and the tool
  # schema serialization — the same yardstick the token estimate uses
  # (name + description + parameters.inspect, executor.rb:957). Outputs are
  # PII-free digests: it never sees message text, only hashes leave this class.
  # Pure stdlib (digest/sha2), no gem, no IO.
  class PrefixFingerprint
    # -> { "prompt" => "sha256…", …, "tool_schemas" => "sha256…",
    #      "prefix" => "sha256…" }
    # Keys are the demodulized, downcased provider ids, in render order.
    # A category with no fragments is absent (not an empty hash).
    # The category digest = SHA256 of the category's fragments joined "\n\n"
    # (the Builder's separator — the digest matches rendered bytes).
    # "prefix" = SHA256 of the category digests concatenated IN CHAIN ORDER
    # (identity categories, then volatile, then tool_schemas) — any divergence
    # anywhere above the boundary changes it.
    def self.compute(system_fragments, tool_serial:)
      digests = {} # category name -> digest, insertion = render order
      grouped = system_fragments.group_by { |f| category(f.source) }
      grouped.each do |name, frags|
        digests[name] = digest(frags.map(&:content).join("\n\n"))
      end
      digests["tool_schemas"] = digest(tool_serial.to_s) unless tool_serial.nil?
      digests["prefix"] = digest(digests.values.join) unless digests.empty?
      digests
    end

    # -> String | nil. The first category (in CURRENT chain order) whose digest
    # differs or is absent from `previous`; else the first PREVIOUS key now
    # absent from the current chain (a vanished block is a divergence too);
    # else nil. nil `previous` (first turn) -> nil. The returned name is a
    # category id — PII-free by construction.
    #
    # The cumulative "prefix" key is deliberately SKIPPED in the scan: its
    # digest changes whenever ANY category moves, so scanning it would shadow a
    # vanished block (every surviving category matches, "prefix" differs, and
    # the vanished-fallback below becomes unreachable — reporting `broke:
    # prefix` instead of the category that actually left).
    def self.invalidation_reason(current, previous)
      return nil unless previous.is_a?(Hash)

      current.each_key do |name|
        next if name == "prefix"

        return name unless previous[name] == current[name]
      end
      (previous.keys - current.keys).first
    end

    def self.category(source) = source.to_s.split("::").last.to_s.downcase
    def self.digest(bytes) = Digest::SHA256.hexdigest(bytes)
  end
end

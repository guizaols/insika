# frozen_string_literal: true

module Harness
  # Profile allowlist semantics, defined once: nil = all; [] = none;
  # [names] = subset. It used to be copied in the Builder, the SkillCatalog and the
  # policies — the rule must live in a single place.
  module Allowlist
    module_function

    # Filters a collection by the allowlist, comparing `key.call(candidate)` (or the
    # candidate itself) against the allowed names.
    def filter(candidates, allow, &key)
      return candidates if allow.nil?
      return [] if allow.empty?

      names = Array(allow).map(&:to_s)
      candidates.select { |c| names.include?((key ? key.call(c) : c).to_s) }
    end

    # Per-item boolean variant (to compose with other filters in a select).
    def allows?(allow, value)
      return true if allow.nil?
      return false if allow.empty?

      Array(allow).map(&:to_s).include?(value.to_s)
    end
  end
end

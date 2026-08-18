# frozen_string_literal: true

module Insika
  module Harvest
    # C3 — the versioned negative list (RFC §4.2): things the harvester must
    # never propose. Pure value object — never touches a store, never authors
    # a rule (D4: the engine applies it, the forge authors it). `parse`
    # accepts BOTH the markdown file shape (frontmatter + rule bullets) and
    # the pack-data array shape ({ rule, pattern, note } hashes), so a rule
    # cannot exist in one and not the other (E2's drift guard).
    #
    # A rule is a phrase or a regex. Phrases match case/accent-folded at WORD
    # boundaries (the RFC-0024 §3.7 hygiene — "NÃO DEVOLVEMOS" is the same
    # word as "não devolvemos"); regexes match the raw OR the folded text (the
    # author may write either spelling, `/…/flags` honored). `matches_name` is
    # the stricter SUBSTRING reading the CI spec uses on skill names.
    class NegativeList
      Rule = Data.define(:rule, :pattern, :note, :regexp)

      # The pt-BR vowel fold — stdlib only, no UnicodeUtils. Both sides of a
      # phrase match are folded through this map.
      FOLD = {
        "á" => "a", "à" => "a", "ã" => "a", "â" => "a",
        "é" => "e", "ê" => "e",
        "í" => "i",
        "ó" => "o", "õ" => "o", "ô" => "o",
        "ú" => "u", "ü" => "u",
        "ç" => "c"
      }.freeze
      FOLD_RE = Regexp.union(FOLD.keys)

      attr_reader :rules

      # A file line: "- `rule-id` — <phrase-or-/regex/> — <note>" (the note
      # may be empty; a phrase may be quoted — `"concorrente"` — and the
      # quotes are not part of the pattern, matching the pack-array shape). A
      # malformed line refuses the WHOLE list — a half-parsed list silently
      # admits what the store banned.

      def self.parse(raw)
        parse!(raw)
      rescue Insika::ValidationError
        nil
      end

      # -> NegativeList. Raises Insika::ValidationError naming the defect —
      # the E2 seed path (`insika harvest:negative import`) uses THIS one.
      def self.parse!(raw)
        new(rules: parse_rules(raw))
      end

      def self.parse_rules(raw)
        return [] if raw.nil?

        case raw
        when String
          file_rules(raw)
        when Array
          array_rules(raw)
        else
          raise Insika::ValidationError, "negative list must be file text or an array of rules"
        end
      end
      private_class_method :parse_rules

      def self.file_rules(text)
        text.each_line.with_index(1).filter_map do |line, index|
          next if line.strip.empty? || line.strip.start_with?("#")

          id_match = /\A`([^`]+)`\s+—\s*/.match(line.strip.delete_prefix("- "))
          raise Insika::ValidationError, "negative list line #{index} is malformed — " \
                                         "expected `- \\`rule-id\\` — <phrase-or-/regex/> — <note>`" if id_match.nil?

          rest = line.strip.delete_prefix("- ").sub(/\A`[^`]+`\s+—\s*/, "")
          # a trailing bare " —" (an empty note) is presentation, not content
          rest = rest.sub(/\s+—\s*\z/, "") if rest.match?(/\s+—\s*\z/)
          pattern, note = rest.split(" — ", 2)
          build_rule(rule: id_match[1], pattern: strip_quotes(pattern.to_s.strip),
                     note: note.to_s.strip, line: index)
        end
      end
      private_class_method :file_rules

      # The file shape quotes a phrase (`"concorrente"`); the quotes are
      # presentation, not part of the pattern — the pack-array shape has none.
      def self.strip_quotes(pattern)
        return pattern[1...-1] if pattern.start_with?('"') && pattern.end_with?('"') && pattern.length >= 2

        pattern
      end
      private_class_method :strip_quotes

      def self.array_rules(entries)
        entries.each_with_index.map do |entry, i|
          unless entry.is_a?(Hash)
            raise Insika::ValidationError, "negative list entry ##{i + 1} is not a { rule, pattern } hash"
          end

          h = Coercion.deep_stringify(entry)
          rule = Coercion.presence(h["rule"])
          pattern = Coercion.presence(h["pattern"])
          raise Insika::ValidationError, "negative list entry ##{i + 1} is missing a rule id" if rule.nil?
          raise Insika::ValidationError, "negative list rule '#{rule}' is missing a pattern" if pattern.nil?

          build_rule(rule: rule, pattern: pattern, note: h["note"].to_s.strip, line: i + 1)
        end
      end
      private_class_method :array_rules

      def self.build_rule(rule:, pattern:, note:, line:)
        Rule.new(rule: rule, pattern: pattern, note: note, regexp: compile_regexp(pattern, rule, line))
      end
      private_class_method :build_rule

      # "/…/flags" -> Regexp; anything else is a literal phrase (regexp nil).
      def self.compile_regexp(pattern, rule, line)
        return nil unless pattern.start_with?("/")

        closing = pattern.rindex("/")
        unless closing && closing > 0
          raise Insika::ValidationError, "negative list rule '#{rule}' (line #{line}) has a malformed regex: #{pattern.inspect}"
        end

        source = pattern[1...closing]
        flags = pattern[(closing + 1)..].to_s
        Regexp.new(source, regexp_flags(flags, rule, line))
      rescue RegexpError => e
        raise Insika::ValidationError,
              "negative list rule '#{rule}' (line #{line}) has a regex that does not compile: #{e.message}"
      end
      private_class_method :compile_regexp

      def self.regexp_flags(flags, rule, line)
        i = flags.include?("i")
        m = flags.include?("m")
        x = flags.include?("x")
        unknown = flags.delete("i").delete("m").delete("x")
        unless unknown.empty?
          raise Insika::ValidationError,
                "negative list rule '#{rule}' (line #{line}) has unsupported regex flags: #{unknown.inspect}"
        end

        (i ? Regexp::IGNORECASE : 0) | (m ? Regexp::MULTILINE : 0) | (x ? Regexp::EXTENDED : 0)
      end
      private_class_method :regexp_flags

      def initialize(rules:)
        @rules = rules
      end

      # -> [Rule] every rule whose pattern matched the text (word-boundary,
      # case + accent folded for phrases; raw-or-folded for regexes). Empty =
      # clean.
      def matches(text)
        haystack = text.to_s
        folded = fold(haystack)
        @rules.select { |r| rule_match?(r, haystack, folded) }
      end

      # -> [Rule] every rule whose pattern appears as a SUBSTRING (the stricter
      # reading the CI spec uses on skill NAMES — a name containing a banned
      # token is banned even mid-word).
      def matches_name(name)
        haystack = name.to_s
        folded = fold(haystack)
        @rules.select { |r| name_match?(r, haystack, folded) }
      end

      # -> Hash { rule => count } — what the run log records.
      def reject_counts(text)
        matches(text).each_with_object({}) { |r, acc| acc[r.rule] = (acc[r.rule] || 0) + 1 }
      end

      private

      def rule_match?(rule, raw, folded)
        if rule.regexp
          rule.regexp.match?(raw) || rule.regexp.match?(folded)
        else
          pattern = fold(rule.pattern)
          folded.match?(/(?:\A|\W)#{Regexp.escape(pattern)}(?:\W|\z)/i)
        end
      end

      def name_match?(rule, raw, folded)
        if rule.regexp
          rule.regexp.match?(raw) || rule.regexp.match?(folded)
        else
          folded.include?(fold(rule.pattern))
        end
      end

      # Case + accent fold for the pt-BR vowels — stdlib only.
      def fold(text)
        text.to_s.downcase.gsub(FOLD_RE, FOLD)
      end
    end
  end
end
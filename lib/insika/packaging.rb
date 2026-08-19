# frozen_string_literal: true

module Insika
  # The single source of the gem payload selection. The
  # gemspec and the domain-boundary audit spec call THE SAME function, so
  # "what ships in the gem" is a fact the suite asserts on, never a prose
  # promise: `git ls-files` (fallback: a glob where there is no .git) filtered
  # to lib/ + docs/ + the four root files, minus the never-ship set.
  #
  # Pure and dependency-free (no git gem, no FileUtils beyond reads) so both
  # the gemspec (built outside the app) and the spec can load it. It does NOT
  # ship anything itself — it answers a list.
  #
  # `domain_content?` is the audit's yardstick: best-effort detection of pt-BR
  # domain content in a payload file. Ruby files are scanned for their string
  # literals, regex literals and heredoc bodies (comments stripped);
  # everything else is scanned as raw text. The token set is the pt-BR
  # vocabulary + the demo persona name (PT_BR_TOKENS). The corpus data files
  # and the audit's own token table live in the spec's named allowlist.
  module Packaging
    # The pt-BR domain vocabulary the audit scans for. `loja`/`shop`/`store`
    # are generic-retail stopwords — the ONE justification the inventory
    # allows (D3); `bia` is the demo persona name (D8).
    #
    # The scan is FOLD-aware: both the scanned text and these words go through
    # `fold` (accents stripped, regex bracket classes like `voc[êe]` collapsed
    # to their canonical chars) before matching. That is what makes the
    # shipped corpus data — whose patterns encode pt-BR as `voc[êe]`,
    # `instru[çc][õo]es` — detectable by the same token table (D1: the
    # boundary holds for the content the inventory names).
    ACCENT_MAP = {
      "á" => "a", "à" => "a", "â" => "a", "ã" => "a", "ä" => "a",
      "é" => "e", "è" => "e", "ê" => "e", "ë" => "e",
      "í" => "i", "ì" => "i", "î" => "i", "ï" => "i",
      "ó" => "o", "ò" => "o", "ô" => "o", "õ" => "o", "ö" => "o",
      "ú" => "u", "ù" => "u", "û" => "u", "ü" => "u",
      "ç" => "c"
    }.freeze
    BRACKET_CLASS = /\[([^\]]*)\]/

    # -> String: the canonical form the token match runs on. A bracket class
    # folds to the deduped canonical chars of its members — `voc[êe]` folds
    # to "voce", matching the folded token "voce" (você).
    def self.fold(text)
      text.to_s.gsub(BRACKET_CLASS) do
        Regexp.last_match(1).chars.map { |c| ACCENT_MAP.fetch(c, c) }.uniq.join
      end.gsub(/[#{ACCENT_MAP.keys.join}]/, ACCENT_MAP)
    end

    TOKEN_WORDS = ["você", "não", "loja", "pedido", "atendente", "obrigad",
                   "conversa", "cliente"].freeze
    PT_BR_VOCABULARY = /\b(?:#{TOKEN_WORDS.map { |w| fold(w) }.join("|")})\b/i
    PERSONA_NAME = /\bbia\b/i
    PT_BR_TOKENS = /(?:#{PT_BR_VOCABULARY.source}|#{PERSONA_NAME.source})/i

    # The never-ship set: the studio JS toolchain (only assets/dist ships) and
    # the docs' own Jekyll Gemfile/config.
    NEVER_SHIP_PREFIXES = ["node_modules", "lib/insika/studio/test/", "lib/insika/studio/assets/src/"].freeze
    NEVER_SHIP_PATHS = %w[
      docs/Gemfile docs/Gemfile.lock docs/_config.yml
      lib/insika/studio/README.md lib/insika/studio/package.json
      lib/insika/studio/package-lock.json lib/insika/studio/tailwind.config.js
    ].freeze

    module_function

    # -> [String] repo-relative file paths the gem ships, in the gemspec's
    # order: `git ls-files` (fallback: glob where there is no .git), filtered
    # to lib/ + docs/ + the four root files, minus the never-ship set.
    def payload_files(root = Dir.pwd)
      Dir.chdir(root) do
        tracked = `git ls-files -z 2>/dev/null`.split("\x0")
        if tracked.empty?
          tracked = Dir.glob("{lib,docs}/**/*", File::FNM_DOTMATCH).reject { |f| File.directory?(f) } +
                    %w[README.md LICENSE CHANGELOG.md bin/insika]
        end
        tracked.select { |file| payload_path?(file) }.reject { |file| excluded?(file) }
      end
    end

    # -> bool: is this repo-relative path part of the payload selection?
    def payload_path?(file)
      file.start_with?("lib/", "docs/") || %w[README.md LICENSE CHANGELOG.md bin/insika].include?(file)
    end

    # -> bool: is this file in the never-ship set?
    def excluded?(file)
      NEVER_SHIP_PREFIXES.any? { |p| file.include?(p) } || NEVER_SHIP_PATHS.include?(file)
    end

    # -> bool: does a payload file hold pt-BR domain content? Best-effort:
    #   - Ruby files: comments stripped, string literals / regex literals /
    #     heredoc bodies scanned;
    #   - everything else: scanned as-is.
    # The token set is the pt-BR vocabulary + the demo persona name; both the
    # text and the vocabulary are FOLDED before matching (accents stripped,
    # bracket classes collapsed), so the corpus data's `voc[êe]`-style
    # patterns are caught by the same table.
    def domain_content?(path)
      text = path.to_s.end_with?(".rb") ? ruby_text(path) : File.read(path)
      fold(text).match?(PT_BR_TOKENS)
    end

    # -> bool: does a payload file mention the demo persona name (`bia`)?
    def persona_content?(path)
      text = path.to_s.end_with?(".rb") ? ruby_text(path) : File.read(path)
      text.match?(PERSONA_NAME)
    end

    # The Ruby source as the audit reads it: heredoc bodies verbatim, string +
    # regex literals, comments stripped. Best-effort by design (D1).
    def ruby_text(path)
      lines = File.readlines(path)
      out = +""
      heredoc = nil
      lines.each do |line|
        if heredoc
          out << line
          heredoc = nil if line.strip == heredoc
          next
        end
        if (m = line.match(HEREDOC_OPEN))
          heredoc = m[1] || m[2] || m[3]
          next
        end
        code = strip_comments(line)
        out << code.scan(STRING_LITERAL).join("\n")
        out << code.scan(REGEX_LITERAL).join("\n")
      end
      out
    end

    # Cuts a line at its first `#` that starts a COMMENT — i.e. a `#` NOT
    # inside a string/regex literal (an interpolation `#{…}` or a literal `#`
    # must survive; a naive strip would corrupt the literal and hide content).
    def strip_comments(line)
      spans = literal_spans(line)
      cut = nil
      line.chars.each_index do |i|
        next unless line[i] == "#"
        next if spans.any? { |b, e| i >= b && i < e }

        cut = i
        break
      end
      cut ? line[0...cut] : line
    end

    # -> [[begin, end), …] spans of the complete string/regex literals in a line.
    def literal_spans(line)
      spans = []
      line.scan(STRING_LITERAL) { spans << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
      line.scan(REGEX_LITERAL) { spans << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
      spans
    end

    HEREDOC_OPEN = /<<[~-]\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z_]\w*))(?:\s*\.\w+)*\s*\z/
    STRING_LITERAL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/
    REGEX_LITERAL = %r{\/(?:[^\/\\\n]|\\.)+\/[a-z]*}

    private_class_method :payload_path?, :excluded?, :ruby_text, :strip_comments, :literal_spans
  end
end

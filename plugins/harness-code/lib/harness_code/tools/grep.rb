# frozen_string_literal: true

require_relative "base"

module HarnessCode
  module Tools
    # Search files in the workspace for lines matching a regular expression.
    # Implemented in pure Ruby (Dir.glob + Regexp) rather than shelling out, so
    # it stays read-only and inside the sandbox — glob results are re-checked
    # against the workspace to defeat symlink escapes. Read-only.
    class Grep < Base
      MAX_MATCHES = 200
      # Per-scan wall-clock budget for regex matching (Ruby 3.2+). A pathological
      # pattern (e.g. `(a+)+$`) against a long line backtracks catastrophically
      # and would otherwise hang the whole reactor — and grep is read-only, so it
      # runs WITHOUT an approval gate. Exceeding this raises Regexp::TimeoutError,
      # which we turn into a fast, structured error instead of a stuck turn.
      PATTERN_TIMEOUT = 2.0

      description "Searches files in the workspace for lines matching a Ruby regular expression. " \
                  "Returns matches as {path, line, text}."
      param :pattern, desc: "Ruby-compatible regular expression"
      param :path, desc: "File or directory to search, relative to the root (default: the root)",
                   required: false

      def name = "grep"

      def execute(pattern:, path: ".")
        guard do
          regexp = Regexp.new(pattern.to_s, timeout: PATTERN_TIMEOUT)
          rel = path.to_s.strip.empty? ? "." : path
          base = workspace.resolve(rel)
          matches = scan(files_under(base), regexp)
          { matches: matches, truncated: matches.size >= MAX_MATCHES }
        rescue Regexp::TimeoutError
          { error: "grep: pattern timed out" }
        end
      end

      private

      def files_under(base)
        return [base] if File.file?(base)

        # FNM_DOTMATCH so dotfiles (.env, .github/…) are searchable — a plain
        # `**/*` glob silently skips them. `.git/` is pruned: it is machine state
        # (objects/refs), not source, and would both pollute results and slow the
        # scan with large packed data.
        Dir.glob(File.join(base, "**", "*"), File::FNM_DOTMATCH)
           .reject { |f| f.split(File::SEPARATOR).include?(".git") }
           .select { |f| File.file?(f) && workspace.inside?(f) }
      end

      def scan(files, regexp)
        matches = []
        files.each do |file|
          File.foreach(file).with_index(1) do |line, number|
            next unless regexp.match?(line)

            matches << { path: workspace.relative(file), line: number, text: line.chomp[0, 300] }
            return matches if matches.size >= MAX_MATCHES
          end
        rescue ArgumentError # binary file / invalid byte sequence — skip
          next
        end
        matches
      end
    end
  end
end

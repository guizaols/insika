# frozen_string_literal: true

require_relative "base"

module HarnessCode
  module Tools
    # Replace an exact string in an existing workspace file. SIDE-EFFECT tool
    # (approval-gated, same as write_file). Fails loudly when `old_string` is
    # missing or not unique — the model must add surrounding context to
    # disambiguate, which prevents accidental multi-site edits.
    class EditFile < Base
      description "Replaces an exact string in an existing workspace file. Fails if the string " \
                  "is not found or is not unique. Requires human approval."
      param :path, desc: "Path to the file, relative to the workspace root"
      param :old_string, desc: "Exact text to replace (must occur exactly once)"
      param :new_string, desc: "Replacement text"

      def name = "edit_file"

      def execute(path:, old_string:, new_string:)
        guard do
          abs = sandbox.resolve(path)
          raise "not a file: #{path}" unless File.file?(abs)

          content = File.read(abs, encoding: "UTF-8")
          occurrences = content.scan(old_string.to_s).size
          raise "old_string not found in #{sandbox.relative(abs)}" if occurrences.zero?
          if occurrences > 1
            raise "old_string is not unique (#{occurrences} matches) — add more surrounding context"
          end

          # Block form so `new_string` is inserted VERBATIM. The 2-arg form of
          # String#sub interprets backreferences (`\0`, `\1`, `\\`, `\k<name>`)
          # in the replacement even when the pattern is a literal string, which
          # would silently corrupt replacements containing a backslash.
          File.write(abs, content.sub(old_string.to_s) { new_string.to_s })
          { path: sandbox.relative(abs), status: "edited" }
        end
      end
    end
  end
end

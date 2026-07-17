# frozen_string_literal: true

require_relative "base"

module HarnessCode
  module Tools
    # Read a UTF-8 text file from the workspace. Read-only (no side_effect, no
    # approval). Caps the returned size so a huge file can't blow the context.
    class ReadFile < Base
      MAX_BYTES = 200_000

      description "Reads a UTF-8 text file from the workspace and returns its contents. " \
                  "Paths are relative to the workspace root."
      param :path, desc: "Path to the file, relative to the workspace root"

      def name = "read_file"

      def execute(path:)
        guard do
          abs = workspace.resolve(path)
          raise "not a file: #{path}" unless File.file?(abs)

          content = File.read(abs, MAX_BYTES + 1, encoding: "UTF-8")
          truncated = content.bytesize > MAX_BYTES
          # `byteslice` can cut through a multibyte UTF-8 char at the cap; `scrub`
          # replaces the resulting invalid trailing bytes so we never emit an
          # invalidly-encoded string to the model.
          body = truncated ? content.byteslice(0, MAX_BYTES).scrub : content
          { path: workspace.relative(abs), content: body, truncated: truncated }
        end
      end
    end
  end
end

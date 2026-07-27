# frozen_string_literal: true

require "fileutils"
require_relative "base"

module InsikaCode
  module Tools
    # Create or overwrite a file in the sandbox. SIDE-EFFECT tool: marked
    # `side_effect: true` in the plugin manifest (so the checkpoint/resume
    # machinery treats it as non-idempotent) and listed in the agent profile's
    # `approvals_required` (so the ToolEnvelope suspends the turn for human
    # approval before it runs). Missing parent directories are created inside the
    # sandbox.
    class WriteFile < Base
      description "Creates or overwrites a file in the workspace with the given content. " \
                  "Creates parent directories as needed. Requires human approval."
      param :path, desc: "Path to the file, relative to the workspace root"
      param :content, desc: "Full UTF-8 content to write"

      def name = "write_file"

      def execute(path:, content:)
        guard do
          abs = sandbox.resolve(path, for_write: true)
          FileUtils.mkdir_p(File.dirname(abs))
          File.write(abs, content.to_s)
          { path: sandbox.relative(abs), bytes: content.to_s.bytesize, status: "written" }
        end
      end
    end
  end
end

# frozen_string_literal: true

require "open3"
require_relative "base"

module HarnessCode
  module Tools
    # Run a shell command with the working directory pinned to the workspace
    # root. HIGHEST-RISK tool of the set: a shell cannot be fully sandboxed by
    # path-resolution alone (a command can `cd ..` or read absolute paths), so
    # its safety rests on the ENGINE's human-approval gate — it is listed in the
    # profile's `approvals_required`, so the ToolEnvelope suspends the turn until
    # an operator approves. `chdir` to the workspace root is the advisory portion
    # of the boundary; approval is the hard control.
    #
    # LIMITATION (prototype): capture2e blocks the calling fiber, so a hung
    # command holds the reactor until the OS returns. The per-call tool_timeout
    # cannot interrupt a blocking syscall. Output is capped. A production runner
    # would spawn detached with a hard kill on timeout.
    class Bash < Base
      MAX_OUTPUT = 40_000

      description "Runs a shell command with the working directory set to the workspace root. " \
                  "Returns {exit_status, output}. Requires human approval."
      param :command, desc: "The shell command to run (executed via /bin/bash -lc)"

      def name = "bash"

      def execute(command:)
        guard do
          cmd = command.to_s
          raise "empty command" if cmd.strip.empty?

          output, status = Open3.capture2e("/bin/bash", "-lc", cmd, chdir: workspace.root)
          { exit_status: status.exitstatus, output: output[0, MAX_OUTPUT] }
        end
      end
    end
  end
end

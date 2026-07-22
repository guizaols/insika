# frozen_string_literal: true

require_relative "base"

module HarnessCode
  module Tools
    # Run a shell command via the sandbox's exec provider (item 35). HIGHEST-RISK
    # tool of the set: with the `local` provider a shell cannot be fully sandboxed
    # by path-resolution alone (it can `cd ..` or read absolute paths), so its
    # safety rests on TWO controls — the ENGINE's human-approval gate (it is listed
    # in the profile's `approvals_required`, so the ToolEnvelope suspends the turn
    # until an operator approves) and, when the profile selects the `docker`
    # provider, real container isolation.
    #
    # Unlike the prototype's raw `capture2e`, the provider enforces a hard-kill
    # wall-clock timeout, so a hung command no longer holds the turn open until the
    # OS returns. Output is capped by the sandbox's `max_output`.
    class Bash < Base
      description "Runs a shell command with the working directory set to the workspace root. " \
                  "Returns {exit_status, output}. Requires human approval."
      param :command, desc: "The shell command to run (executed via the sandbox provider)"

      def name = "bash"

      def execute(command:)
        guard do
          cmd = command.to_s
          raise "empty command" if cmd.strip.empty?

          result = sandbox.exec(cmd)
          if result.timed_out?
            { exit_status: nil, output: result.output, timed_out: true,
              error: "command exceeded #{sandbox.timeout}s and was killed" }
          else
            { exit_status: result.exit_status, output: result.output }
          end
        end
      end
    end
  end
end

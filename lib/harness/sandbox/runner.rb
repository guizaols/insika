# frozen_string_literal: true

require "open3"

module Harness
  module Sandbox
    # Structured result of a sandboxed command. `timed_out` distinguishes a
    # deadline kill (exit_status nil) from a normal exit. `output` is the combined
    # stdout+stderr, already clipped to the provider's cap.
    Result = Data.define(:exit_status, :output, :timed_out) do
      def timed_out? = timed_out
      # Shape returned to the model by the bash tool (parity with the prototype).
      def to_h = { exit_status: exit_status, output: output, timed_out: timed_out }
    end

    # Spawns a command with a REAL hard-kill timeout, shared by every exec
    # provider. Unlike the prototype's `Open3.capture2e` (which blocks
    # uninterruptibly — a hung command holds the fiber until the OS returns), this
    # bounds wall-clock: on expiry the process (and, via its own process group,
    # any children) is force-killed and whatever partial output was captured is
    # returned with `timed_out: true`.
    #
    # Stdlib `Timeout.timeout` is deliberately NOT used (forbidden by the engine's
    # fiber contract, see errors.rb); the deadline is enforced by
    # `Thread#join(timeout)` — a single bounded blocking call — and the reader
    # runs on its own thread so partial output survives the kill.
    module Runner
      # Grace period for the output reader to drain after the process is killed.
      DRAIN_TIMEOUT = 2

      module_function

      # argv:      the command as an argv array (never a shell string — no
      #            re-interpretation by the host shell).
      # chdir:     working directory of the spawned process.
      # kill:      optional extra teardown (e.g. `docker kill <name>`); the
      #            process group is ALWAYS killed regardless.
      def run(argv, chdir:, timeout:, max_output:, env: {}, kill: nil)
        # pgroup: true -> the child is a new group leader (pgid == pid), so a
        # single kill on the negated pid reaps the command AND anything it forked.
        Open3.popen2e(env, *argv, chdir: chdir, pgroup: true) do |stdin, out, wait_thr|
          stdin.close
          reader = Thread.new { out.read }

          if wait_thr.join(timeout).nil?
            terminate(wait_thr.pid, kill)
            Result.new(exit_status: nil, output: drain(reader, max_output), timed_out: true)
          else
            Result.new(exit_status: wait_thr.value.exitstatus,
                       output: drain(reader, max_output), timed_out: false)
          end
        end
      end

      # Kill the whole process group, then run any provider-specific teardown.
      # ESRCH (already gone) / EPERM are benign races — the process is dying.
      def terminate(pid, kill)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      ensure
        kill&.call
      end

      # Collect the reader's output within a grace window. After a kill the write
      # end closes and `out.read` returns promptly; the bound guards a reader that
      # somehow does not (returns "" rather than blocking the fiber forever).
      def drain(reader, max_output)
        return "" if reader.join(DRAIN_TIMEOUT).nil?

        (reader.value || "")[0, max_output]
      end
    end
  end
end

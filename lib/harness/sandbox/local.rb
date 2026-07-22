# frozen_string_literal: true

require_relative "runner"

module Harness
  module Sandbox
    # Default exec provider: runs the command IN-PROCESS on the host, with the
    # working directory pinned to the sandbox root. This is the "narrowest sandbox
    # that supports the task" for trusted/local operation — cheap, no daemon, no
    # image pull. It is NOT an isolation boundary for a shell (a command can still
    # read absolute paths or `cd ..`); that is why shell tools stay approval-gated
    # and why the `docker` provider exists for untrusted execution.
    #
    # The improvement over the prototype's raw `capture2e` is the real hard-kill
    # timeout (via Runner): a hung command no longer holds the turn open until the
    # OS returns.
    class Local
      # `-c` (non-login): a login shell would source ~/.bash_profile on every
      # call, adding latency and letting host dotfiles mutate PATH/env under the
      # command — surprising for a sandboxed tool.
      def initialize(shell: "/bin/bash")
        @shell = shell
      end

      def exec(command, root:, timeout:, max_output:)
        Runner.run([@shell, "-c", command.to_s],
                   chdir: root, timeout: timeout, max_output: max_output)
      end

      def to_s = "local(#{@shell})"
    end
  end
end

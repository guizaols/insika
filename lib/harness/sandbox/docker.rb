# frozen_string_literal: true

require "securerandom"
require_relative "runner"

module Harness
  module Sandbox
    # Isolated exec provider: runs the command inside a throwaway Docker container
    # (`docker run --rm`) with the sandbox root bind-mounted at a fixed workdir.
    # This is the isolation boundary the `local` provider is NOT — a real target
    # for UNTRUSTED shell execution.
    #
    # "Narrowest sandbox that supports the task": only the risky part — shell exec
    # — is containerized. The FS tools (read/write/edit/grep) keep operating on
    # the host path, confined by the `Boundary`; the container sees the SAME bytes
    # through the bind mount, so a file the model writes is immediately visible to
    # a subsequent `bash` call and vice-versa.
    #
    # Defaults are conservative: `--network none` (no egress from the container),
    # a memory cap and a cpu cap, and a minimal image. All are overridable via the
    # profile's `sandbox` config (config-over-code).
    class Docker
      DEFAULTS = {
        "image" => "alpine:3.20",
        "network" => "none",
        "memory" => "512m",
        "cpus" => "1.0",
        "workdir" => "/workspace",
        "shell" => "/bin/sh",
        "docker_bin" => "docker"
      }.freeze

      def initialize(config = {})
        cfg = DEFAULTS.merge(config.transform_keys(&:to_s).compact)
        @image      = cfg["image"]
        @network    = cfg["network"]
        @memory     = cfg["memory"]
        @cpus       = cfg["cpus"].to_s
        @workdir    = cfg["workdir"]
        @shell      = cfg["shell"]
        @docker_bin = cfg["docker_bin"]
      end

      # PURE argv builder — unit-testable without Docker present. `--name` lets
      # the timeout teardown `docker kill` the exact container (killing the client
      # process alone does not stop it).
      def argv(command, root:, name:)
        [@docker_bin, "run", "--rm", "--name", name,
         "--network", @network, "--memory", @memory, "--cpus", @cpus,
         "--volume", "#{root}:#{@workdir}:rw", "--workdir", @workdir,
         @image, @shell, "-c", command.to_s]
      end

      def exec(command, root:, timeout:, max_output:)
        name = "harness-sbx-#{SecureRandom.hex(8)}"
        Runner.run(argv(command, root: root, name: name),
                   chdir: root, timeout: timeout, max_output: max_output,
                   # On the wall-clock deadline, stop the container by name; the
                   # `--rm` then removes it. Squelch output — this is teardown.
                   kill: -> { system(@docker_bin, "kill", name, out: File::NULL, err: File::NULL) })
      end

      # Whether the Docker daemon is reachable. Used at boot to fail fast (or warn)
      # instead of discovering it mid-turn.
      def available?
        system(@docker_bin, "version", out: File::NULL, err: File::NULL)
      rescue StandardError
        false
      end

      def to_s = "docker(#{@image}, network=#{@network})"
    end
  end
end

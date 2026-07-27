# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Insika::Sandbox do
  around do |example|
    Dir.mktmpdir { |dir| @root = File.realpath(dir); example.run }
  end

  describe ".build" do
    it "defaults to the local provider and cwd-derived confinement" do
      env = described_class.build("root" => @root)
      expect(env).to be_a(described_class::Env)
      expect(env.provider).to be_a(described_class::Local)
      expect(env.root).to eq(@root)
    end

    it "tolerates symbol keys (deep_stringify at the door)" do
      env = described_class.build(root: @root, timeout: 7)
      expect(env.root).to eq(@root)
      expect(env.timeout).to eq(7)
    end

    it "selects the docker provider by data (config-over-code)" do
      env = described_class.build("provider" => "docker", "root" => @root,
                                  "image" => "ruby:3.3", "network" => "none")
      expect(env.provider).to be_a(described_class::Docker)
    end

    it "raises on an unknown provider" do
      expect { described_class.build("provider" => "banana", "root" => @root) }
        .to raise_error(ArgumentError, /unknown sandbox provider/)
    end

    it "applies the default limits when unspecified" do
      env = described_class.build("root" => @root)
      expect(env.timeout).to eq(described_class::DEFAULT_TIMEOUT)
      expect(env.max_output).to eq(described_class::DEFAULT_MAX_OUTPUT)
    end
  end

  describe "Env#resolve (delegates to the boundary)" do
    subject(:env) { described_class.build("root" => @root) }

    it "confines a path to the root" do
      expect(env.resolve("a.txt")).to eq(File.join(@root, "a.txt"))
    end

    it "raises Escape on traversal" do
      expect { env.resolve("../x") }.to raise_error(described_class::Escape)
    end
  end

  describe "Env#exec via the local provider" do
    subject(:env) { described_class.build("root" => @root, "timeout" => 2) }

    it "runs a command with the working directory pinned to the root" do
      result = env.exec("pwd")
      expect(result.exit_status).to eq(0)
      expect(result).not_to be_timed_out
      expect(File.realpath(result.output.strip)).to eq(@root)
    end

    it "captures a non-zero exit status" do
      expect(env.exec("exit 3").exit_status).to eq(3)
    end

    it "captures stderr into the combined output" do
      expect(env.exec("echo oops 1>&2").output).to include("oops")
    end

    it "clips output to max_output" do
      env = described_class.build("root" => @root, "max_output" => 5)
      expect(env.exec("printf 'abcdefghij'").output.bytesize).to eq(5)
    end

    # A command's output is arbitrary bytes, and it becomes a tool result — so it
    # gets JSON-serialized into the transcript and the SSE stream. Anything not
    # valid UTF-8 has to die here, at the boundary, not at serialization time.
    it "keeps accented output serializable" do
      output = env.exec("printf 'não 🚀'").output

      expect(output).to eq("não 🚀")
      expect { JSON.generate(o: output) }.not_to raise_error
    end

    it "scrubs invalid bytes out of the output" do
      output = env.exec("printf 'ok \\303('").output

      expect(output).to be_valid_encoding
      expect { JSON.generate(o: output) }.not_to raise_error
    end

    # The real improvement over the prototype's capture2e: a hung command is
    # hard-killed at the deadline instead of holding the caller until the OS
    # returns. Uses a short timeout and asserts it trips fast.
    it "hard-kills a command that exceeds the timeout" do
      env = described_class.build("root" => @root, "timeout" => 1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = env.exec("sleep 10")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result).to be_timed_out
      expect(result.exit_status).to be_nil
      expect(elapsed).to be < 5 # killed near the 1s deadline, not after 10s
    end

    it "kills child processes too (process-group kill)" do
      env = described_class.build("root" => @root, "timeout" => 1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # A child sleep in a subshell: a naive kill of only the shell would orphan
      # it and the pipe would stay open past the deadline.
      result = env.exec("sh -c 'sleep 10' & sleep 10")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result).to be_timed_out
      expect(elapsed).to be < 6
    end
  end

  describe Insika::Sandbox::Docker do
    subject(:docker) do
      described_class.new("image" => "ruby:3.3", "network" => "none",
                          "memory" => "256m", "cpus" => "2")
    end

    # The argv is a PURE builder — the container isolation policy is proven
    # without needing a Docker daemon in CI.
    it "builds a `docker run` argv with the declared isolation policy" do
      argv = docker.argv("ls -la", root: "/ws", name: "sbx-1")
      expect(argv).to eq(%w[
        docker run --rm --name sbx-1
        --network none --memory 256m --cpus 2
        --volume /ws:/workspace:rw --workdir /workspace
        ruby:3.3 /bin/sh -c
      ] + ["ls -la"])
    end

    it "defaults to conservative isolation (no network, minimal image)" do
      argv = described_class.new.argv("true", root: "/ws", name: "n")
      expect(argv).to include("--network", "none")
      expect(argv).to include("--rm")
      expect(argv.last(3)).to eq(["/bin/sh", "-c", "true"])
    end

    describe "#exec (integration)", if: system("docker", "version", out: File::NULL, err: File::NULL) do
      it "runs a command inside a container against the bind-mounted root" do
        File.write(File.join(@root, "marker.txt"), "hello-from-host")
        env = Insika::Sandbox.build("provider" => "docker", "root" => @root,
                                     "image" => "alpine:3.20", "timeout" => 30)
        result = env.exec("cat marker.txt")
        expect(result.exit_status).to eq(0)
        expect(result.output).to include("hello-from-host")
      end
    end
  end
end

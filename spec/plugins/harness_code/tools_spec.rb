# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

PLUGIN_LIB = File.expand_path("../../../plugins/harness-code/lib", __dir__)
%w[base read_file list_dir grep write_file edit_file bash].each do |f|
  require File.join(PLUGIN_LIB, "harness_code/tools/#{f}")
end

# Exercises the tools' behaviour through #execute directly (the RubyLLM tool-loop
# is not involved), mirroring spec/insika/tools/remember_spec.rb. Every tool
# shares one Workspace, so the sandbox is proven once per tool: a path escape
# comes back as a structured { error: } result, never an exception.
RSpec.describe "HarnessCode tools" do
  around do |example|
    Dir.mktmpdir { |dir| @root = File.realpath(dir); example.run }
  end

  let(:sandbox) { Insika::Sandbox.build("root" => @root) }

  def write(rel, content)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  describe HarnessCode::Tools::ReadFile do
    subject(:tool) { described_class.new(sandbox: sandbox) }

    it "has the plain name 'read_file' (not the class-derived one)" do
      expect(tool.name).to eq("read_file")
    end

    it "reads a file inside the workspace" do
      write("hello.txt", "hi there")
      expect(tool.execute(path: "hello.txt"))
        .to eq(path: "hello.txt", content: "hi there", truncated: false)
    end

    it "returns a sandbox error for a path outside the workspace" do
      result = tool.execute(path: "../../etc/passwd")
      expect(result[:error]).to match(/sandbox/)
    end
  end

  describe HarnessCode::Tools::ListDir do
    subject(:tool) { described_class.new(sandbox: sandbox) }

    it "lists files and dirs at the root" do
      write("a.rb", "1")
      FileUtils.mkdir_p(File.join(@root, "sub"))
      result = tool.execute
      expect(result[:path]).to eq(".")
      expect(result[:entries]).to include({ name: "a.rb", type: "file" },
                                          { name: "sub", type: "dir" })
    end

    it "rejects escaping the workspace" do
      expect(tool.execute(path: "..")[:error]).to match(/sandbox/)
    end
  end

  describe HarnessCode::Tools::Grep do
    subject(:tool) { described_class.new(sandbox: sandbox) }

    it "finds matching lines with path and line number" do
      write("app/x.rb", "alpha\nTODO fix\nbeta\n")
      result = tool.execute(pattern: "TODO")
      expect(result[:matches]).to contain_exactly(
        { path: "app/x.rb", line: 2, text: "TODO fix" }
      )
      expect(result[:truncated]).to be(false)
    end

    it "rejects escaping the workspace" do
      expect(tool.execute(pattern: "x", path: "/etc")[:error]).to match(/sandbox/)
    end

    it "searches dotfiles but prunes .git" do
      write(".env", "SECRET=needle\n")
      write(".git/config", "needle\n")
      paths = tool.execute(pattern: "needle")[:matches].map { |m| m[:path] }
      expect(paths).to include(".env")
      expect(paths).not_to include(".git/config")
    end

    # ReDoS guard: a catastrophic pattern against a crafted line backtracks
    # exponentially and, without a timeout, would hang the reactor forever (grep
    # is read-only, so it runs with NO approval gate). It must fail fast with a
    # structured error, bounded by Grep::PATTERN_TIMEOUT. The backreference here
    # (`\1`) defeats the engine's memoization optimization, so the blow-up is
    # real on Ruby 3.2+, not something the optimizer quietly linearizes.
    it "returns a fast error for a catastrophic pattern instead of hanging" do
      write("evil.txt", "#{"a" * 60}b")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = tool.execute(pattern: '^(a+)+\1$')
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result[:error]).to match(/timed out/)
      # Well under a hang: the guard trips near PATTERN_TIMEOUT (2s), not runaway.
      expect(elapsed).to be < (HarnessCode::Tools::Grep::PATTERN_TIMEOUT + 3)
    end
  end

  describe HarnessCode::Tools::WriteFile do
    subject(:tool) { described_class.new(sandbox: sandbox) }

    it "creates a file (and parent dirs) inside the workspace" do
      result = tool.execute(path: "nested/new.txt", content: "data")
      expect(result).to include(path: "nested/new.txt", status: "written")
      expect(File.read(File.join(@root, "nested/new.txt"))).to eq("data")
    end

    it "refuses to write outside the workspace (no file is created)" do
      target = File.join(File.dirname(@root), "escape.txt")
      expect(tool.execute(path: "../escape.txt", content: "x")[:error]).to match(/sandbox/)
      expect(File.exist?(target)).to be(false)
    end

    # Sandbox-escape regression: a symlink inside the workspace whose target is
    # OUTSIDE must not be followed — writing through it would clobber an external
    # file while every string/parent check still passes.
    it "refuses to write THROUGH a symlink that points outside the workspace" do
      outside = Dir.mktmpdir
      external = File.join(outside, "victim.txt")
      File.write(external, "original")
      File.symlink(external, File.join(@root, "link.txt"))

      expect(tool.execute(path: "link.txt", content: "pwned")[:error]).to match(/sandbox/)
      expect(File.read(external)).to eq("original")
    ensure
      FileUtils.remove_entry(outside) if outside
    end
  end

  describe HarnessCode::Tools::EditFile do
    subject(:tool) { described_class.new(sandbox: sandbox) }

    it "replaces a unique string" do
      write("f.rb", "x = 1\ny = 2\n")
      expect(tool.execute(path: "f.rb", old_string: "x = 1", new_string: "x = 42"))
        .to eq(path: "f.rb", status: "edited")
      expect(File.read(File.join(@root, "f.rb"))).to eq("x = 42\ny = 2\n")
    end

    it "fails when the string is not unique" do
      write("f.rb", "a\na\n")
      expect(tool.execute(path: "f.rb", old_string: "a", new_string: "b")[:error])
        .to match(/not unique/)
    end

    it "fails when the string is not found" do
      write("f.rb", "a\n")
      expect(tool.execute(path: "f.rb", old_string: "zzz", new_string: "b")[:error])
        .to match(/not found/)
    end

    it "rejects escaping the workspace" do
      expect(tool.execute(path: "../f", old_string: "a", new_string: "b")[:error])
        .to match(/sandbox/)
    end

    # Regression: String#sub(pattern, replacement) interprets backreferences
    # (\0, \1, \\, \k<name>) in the replacement even with a literal string
    # pattern. The block form must be used so new_string lands verbatim.
    it "writes new_string verbatim even when it contains backslash sequences" do
      write("f.rb", "REPLACE_ME\n")
      new_string = 'a\0b\1c\\\\d\k<x>'
      expect(tool.execute(path: "f.rb", old_string: "REPLACE_ME", new_string: new_string))
        .to eq(path: "f.rb", status: "edited")
      expect(File.read(File.join(@root, "f.rb"))).to eq("#{new_string}\n")
    end
  end

  describe HarnessCode::Tools::Bash do
    subject(:tool) { described_class.new(sandbox: sandbox) }

    it "runs a command with the working directory pinned to the workspace root" do
      result = tool.execute(command: "pwd")
      expect(result[:exit_status]).to eq(0)
      expect(File.realpath(result[:output].strip)).to eq(@root)
    end

    it "captures a non-zero exit status" do
      expect(tool.execute(command: "exit 3")[:exit_status]).to eq(3)
    end
  end
end

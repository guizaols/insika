# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

PLUGIN_LIB = File.expand_path("../../../plugins/harness-code/lib", __dir__)
require File.join(PLUGIN_LIB, "harness_code/workspace")
%w[base read_file list_dir grep write_file edit_file bash].each do |f|
  require File.join(PLUGIN_LIB, "harness_code/tools/#{f}")
end

# Exercises the tools' behaviour through #execute directly (the RubyLLM tool-loop
# is not involved), mirroring spec/harness/tools/remember_spec.rb. Every tool
# shares one Workspace, so the sandbox is proven once per tool: a path escape
# comes back as a structured { error: } result, never an exception.
RSpec.describe "HarnessCode tools" do
  around do |example|
    Dir.mktmpdir { |dir| @root = File.realpath(dir); example.run }
  end

  let(:workspace) { HarnessCode::Workspace.new(@root) }

  def write(rel, content)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  describe HarnessCode::Tools::ReadFile do
    subject(:tool) { described_class.new(workspace: workspace) }

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
    subject(:tool) { described_class.new(workspace: workspace) }

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
    subject(:tool) { described_class.new(workspace: workspace) }

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
  end

  describe HarnessCode::Tools::WriteFile do
    subject(:tool) { described_class.new(workspace: workspace) }

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
  end

  describe HarnessCode::Tools::EditFile do
    subject(:tool) { described_class.new(workspace: workspace) }

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
  end

  describe HarnessCode::Tools::Bash do
    subject(:tool) { described_class.new(workspace: workspace) }

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
